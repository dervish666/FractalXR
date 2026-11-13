#!/usr/bin/env python3
"""Render a data-driven trailer through the real app, then cut it together with ffmpeg.

Each shot runs in its own Godot process (tools/trailer.gd) that writes raw frames into a FIFO
read by ffmpeg. The edit (transitions, title card, fades) is one ffmpeg filter graph built
from data/trailer.json, so changing the cut never needs a code change.
"""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import time


PROJ = Path(os.environ["PROJ"])
MODES = {"FLAME", "BULB", "GROUND", "TREE", "IFS"}
# ffmpeg xfade transitions that read well on fractal material; "cut" is a straight join.
TRANSITIONS = {"cut", "fade", "fadeblack", "fadewhite", "dissolve", "zoomin", "circleopen",
               "circleclose", "radial", "hblur", "fadegrays", "smoothup", "smoothdown",
               "smoothleft", "smoothright", "distance"}
TRACKS = {"colour_cycle", "sim_speed", "ground_zoom", "ground_hue", "ifs_depth", "bulb_clock",
          "subject_pos", "subject_scale", "subject_rot"}
EVENTS = {"theme", "flame_morph", "ifs_morph", "dive", "galaxy", "cycle"}
FONT = PROJ / "fonts/SpaceGrotesk-VF.ttf"
COLOUR = ["-colorspace", "bt709", "-color_primaries", "bt709", "-color_trc", "bt709",
          "-color_range", "tv"]


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format",
        "-of", "json", str(path)]))


def frames_of(seconds, fps):
    return math.floor(seconds * fps + 0.5)


def finite(values):
    return all(isinstance(v, (int, float)) and math.isfinite(v) for v in values)


def check_keys(name, keys, width):
    if not keys:
        raise ValueError(f"{name} needs keys")
    last = -1.0
    for k in keys:
        if len(k) != 2 or not finite([k[0]]) or k[0] <= last:
            raise ValueError(f"{name} keys must be [time, value] with increasing times")
        last = k[0]
        value = k[1] if isinstance(k[1], list) else [k[1]]
        if len(value) != width or not finite(value):
            raise ValueError(f"{name} values must have {width} finite numbers")


def validate(data, fps):
    shots = data["shots"]
    if not shots:
        raise ValueError("empty shot list")
    ids = set()
    for n, s in enumerate(shots):
        sid = s.get("id", "")
        if not re.fullmatch(r"[a-z0-9_-]+", sid) or sid in ids:
            raise ValueError("shot ids must be unique safe filenames")
        ids.add(sid)
        if s["mode"] not in MODES:
            raise ValueError(f"unknown mode in {sid}")
        if not isinstance(s.get("preset"), str) or not s["preset"]:
            raise ValueError(f"{sid}: each shot needs a preset name")
        if not 0 < s["duration"] <= 60 or frames_of(s["duration"], fps) < 2:
            raise ValueError(f"{sid}: invalid duration")
        cam = s.get("camera", {})
        if "orbit" in cam:
            o = cam["orbit"]
            for key in ("centre", "radius", "height", "angle"):
                if key not in o:
                    raise ValueError(f"{sid}: orbit needs {key}")
        else:
            keys = cam.get("keys", [])
            if not keys:
                raise ValueError(f"{sid}: camera needs keys or an orbit")
            last = -1.0
            for k in keys:
                if k["t"] <= last or len(k["pos"]) != 3 or len(k["look"]) != 3:
                    raise ValueError(f"{sid}: camera keys need increasing t, pos and look")
                if not finite(k["pos"] + k["look"] + [k.get("fov", 50), k.get("roll", 0)]):
                    raise ValueError(f"{sid}: camera values must be finite")
                last = k["t"]
        for name, spec in s.get("tracks", {}).items():
            if name not in TRACKS:
                raise ValueError(f"{sid}: unsupported track {name}")
            keys = spec["keys"] if isinstance(spec, dict) else spec
            check_keys(f"{sid}.{name}", keys, 3 if name in {"subject_pos", "subject_rot"} else 1)
        for e in s.get("events", []):
            if e.get("do") not in EVENTS or not finite([e.get("at", -1)]) or e["at"] < 0:
                raise ValueError(f"{sid}: bad event {e}")
        if not isinstance(s.get("post", ""), str):
            raise ValueError(f"{sid}: post must be an ffmpeg filter string")
        if s["mode"] == "GROUND" and (len(s.get("ground_centre", [])) != 2 or not s.get("ground_wpu", 0) > 0):
            raise ValueError(f"{sid}: GROUND needs ground_centre and a positive ground_wpu")
        tr = s.get("transition", data.get("transition", {"type": "fade", "seconds": 0.5}))
        if n == 0:
            continue
        if tr["type"] not in TRANSITIONS:
            raise ValueError(f"{sid}: unknown transition {tr['type']}")
        if tr["type"] != "cut" and not 0 < tr["seconds"] < min(s["duration"], shots[n - 1]["duration"]):
            raise ValueError(f"{sid}: a transition must be shorter than both shots it joins")
    return shots


def transition_of(data, shots, n, fps):
    tr = shots[n].get("transition", data.get("transition", {"type": "fade", "seconds": 0.5}))
    if tr["type"] == "cut":
        return "cut", 0
    return tr["type"], frames_of(tr["seconds"], fps)


def render_shot(base, snapshot, index, shot, args, out, kind):
    name = shot["id"]
    width, height = map(int, args.resolution.split("x"))
    logpath = out / f"{name}.log"
    clip = out / f"{name}.mp4"
    # A free local port for ffmpeg to listen on; trailer.gd connects and streams raw frames.
    with socket.socket() as probe_socket:
        probe_socket.bind(("127.0.0.1", 0))
        port = probe_socket.getsockname()[1]
    command = base + ["--rendering-method", "mobile", "--resolution", args.resolution,
                      "--position", "0,0", "--disable-vsync", "--script", "tools/trailer.gd",
                      "--", str(snapshot), str(index), str(args.fps), str(out), kind, str(port)]
    encoder = None
    # The root viewport takes the project's viewport size, not the window's: an exclusive
    # override sets it for this process and is always removed.
    override = PROJ / "override.cfg"
    with override.open("x") as config:
        config.write(f"[display]\nwindow/size/viewport_width={width}\nwindow/size/viewport_height={height}\n")
    try:
        if kind == "movie":
            encoder = subprocess.Popen(
                ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "rawvideo",
                 "-pix_fmt", "rgba", "-s", args.resolution, "-r", str(args.fps),
                 "-i", f"tcp://127.0.0.1:{port}?listen=1&listen_timeout={args.timeout * 1000}",
                 "-vf", "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p",
                 "-c:v", "libx264", "-preset", "veryfast", "-crf", "12", *COLOUR, str(clip)],
                stderr=(out / f"{name}.ffmpeg.log").open("w"))
        with logpath.open("w") as log:
            godot_ok = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                      timeout=args.timeout).returncode == 0
        if encoder is not None and godot_ok:
            encoder.wait(timeout=300)
    finally:
        override.unlink()
        if encoder is not None and encoder.poll() is None:
            encoder.kill()
            encoder.wait()
    text = logpath.read_text(errors="replace")
    if "TRAILERSHOT PASS" not in text or re.search(r"SCRIPT ERROR|SHADER ERROR|Parse Error|TRAILERSHOT FAIL", text):
        raise RuntimeError(f"Godot failed on {name}, see {logpath}")
    frames = frames_of(shot["duration"], args.fps)
    if kind == "movie":
        if encoder.returncode != 0:
            raise RuntimeError(f"ffmpeg failed on {name}, see {out / (name + '.ffmpeg.log')}")
        video = next(s for s in probe(clip)["streams"] if s["codec_type"] == "video")
        if (video["width"], video["height"]) != (width, height) or int(video["nb_read_frames"]) != frames:
            raise RuntimeError(f"{name}: wrong clip size or frame count {video['width']}x{video['height']} {video['nb_read_frames']}")
    settle = re.search(r"settle_frames=(\d+)", text)
    return dict(id=name, mode=shot["mode"], preset=shot["preset"], frames=frames,
                duration=frames / args.fps, settle_frames=int(settle.group(1)) if settle else 0)


def strip_sheet(out, manifest, name):
    """One row of six frames per shot, labelled, under 1500 px wide."""
    rows = []
    for entry in manifest:
        sid = entry["id"]
        pics = [str(out / "strips" / f"{sid}_{k}.png") for k in range(6)]
        row = out / "strips" / f"{sid}-row.jpg"
        run(["montage", *pics, "-geometry", "236x133+2+2", "-tile", "6x1",
             "-background", "#101018", str(row)])
        rows.append(row)
    montage = ["montage", "-font", "/System/Library/Fonts/Supplemental/Arial.ttf",
               "-background", "#101018", "-fill", "white", "-pointsize", "14"]
    for entry, row in zip(manifest, rows):
        montage += ["-label", f"{entry['id']}  {entry['duration']:.2f}s", str(row)]
    montage += ["-geometry", "+4+6", "-tile", "1x", str(out / name)]
    run(montage)


def clip_filmstrips(out, manifest, fps):
    """Six frames across each encoded clip, plus one sheet of all of them."""
    (out / "filmstrips").mkdir(exist_ok=True)
    rows = []
    for entry in manifest:
        sid = entry["id"]
        n = entry["frames"]
        picks = "+".join(f"eq(n\\,{round(k * (n - 1) / 5)})" for k in range(6))
        row = out / "filmstrips" / f"{sid}.jpg"
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(out / f"{sid}.mp4"),
             "-vf", f"select='{picks}',scale=236:-2,tile=6x1:padding=4:color=0x101018",
             "-frames:v", "1", "-q:v", "3", str(row)])
        rows.append(row)
    montage = ["montage", "-font", "/System/Library/Fonts/Supplemental/Arial.ttf",
               "-background", "#101018", "-fill", "white", "-pointsize", "14"]
    for entry, row in zip(manifest, rows):
        montage += ["-label", f"{entry['id']}  {entry['mode']} / {entry['preset']}  {entry['duration']:.2f}s", str(row)]
    montage += ["-geometry", "+4+6", "-tile", "1x", str(out / "filmstrips.jpg")]
    run(montage)


def title_png(data, out, width, height):
    card = data.get("title_card", {})
    path = out / "title.png"
    scale = height / 1440
    title = card.get("text", "FractalXR")
    line = card.get("line", "")
    big = round(card.get("size", 200) * scale)
    small = round(big * 0.29)
    # Centre of the text block as a share of the frame height, so the subject can sit above it.
    dy = round((card.get("y", 0.5) - 0.5) * height)
    # A soft dark pool behind the words keeps them readable over a bright frame without a box.
    # Drawn small and blurred, then scaled up: a full-size blur this wide takes minutes.
    w8, h8 = width // 8, height // 8
    cy = round(height * card.get("y", 0.5)) // 8
    run(["magick", "-size", f"{w8}x{h8}", "xc:none", "-fill", f"rgba(0,0,0,{card.get('shade', 0.6)})",
         "-draw", f"ellipse {w8 // 2},{cy} {round(w8 * 0.3)},{round(h8 * 0.13)} 0,360",
         "-channel", "A", "-blur", f"0x{round(h8 * 0.08)}", "+channel",
         "-resize", f"{width}x{height}!", str(out / "title-shade.png")])
    run(["magick", str(out / "title-shade.png"),
         "-font", str(FONT), "-fill", "white", "-gravity", "center",
         # The variable font opens at its light instance; a hairline stroke gives the title weight.
         "-stroke", "white", "-strokewidth", str(round(2.5 * scale, 1)),
         "-pointsize", str(big), "-kerning", str(round(6 * scale)),
         "-annotate", f"+0{dy - round(big * 0.22):+d}", title,
         "-stroke", "none", "-fill", "#ECE8F6", "-pointsize", str(small), "-kerning", str(round(2 * scale)),
         "-annotate", f"+0{dy + round(big * 0.6):+d}", line, str(path)])
    return path


def assemble(data, shots, manifest, out, args):
    """The edit: transitions between clips, then title, fades and grade, one encode."""
    fps = args.fps
    width, height = map(int, args.resolution.split("x"))
    inputs = []
    graph = []
    shots_by_id = {s["id"]: s for s in shots}
    for i, entry in enumerate(manifest):
        inputs += ["-i", str(out / f"{entry['id']}.mp4")]
        # A shot's own "post" filter (a denoise, a grade) runs on its clip before the cut.
        post = shots_by_id[entry["id"]].get("post", "")
        post = f"{post}," if post else ""
        graph.append(f"[{i}:v]setpts=PTS-STARTPTS,{post}fps={fps},settb=1/{fps},format=yuv420p[s{i}]")
    total = manifest[0]["frames"]
    prev = "s0"
    cuts = []
    for i in range(1, len(manifest)):
        kind, overlap = transition_of(data, shots, i, fps)
        label = f"x{i}"
        if kind == "cut":
            graph.append(f"[{prev}][s{i}]concat=n=2:v=1:a=0,settb=1/{fps}[{label}]")
        else:
            offset = (total - overlap) / fps
            graph.append(f"[{prev}][s{i}]xfade=transition={kind}:duration={overlap / fps:.6f}:offset={offset:.6f}[{label}]")
        cuts.append(dict(into=manifest[i]["id"], transition=kind, at=round((total - overlap) / fps, 3),
                         seconds=round(overlap / fps, 3)))
        total += manifest[i]["frames"] - overlap
        prev = label
    duration = total / fps
    card = data.get("title_card")
    finish = data.get("finish", {})
    tail = []
    grade = finish.get("grade", "")
    if grade:
        tail.append(grade)
    fade_in = finish.get("fade_in", 0.0)
    fade_out = finish.get("fade_out", 0.0)
    if fade_in > 0:
        tail.append(f"fade=t=in:st=0:d={fade_in}")
    chain = f"[{prev}]" + (",".join(tail) if tail else "null") + "[g]"
    graph.append(chain)
    prev = "g"
    if card:
        path = title_png(data, out, width, height)
        idx = len(manifest)
        inputs += ["-loop", "1", "-framerate", str(fps), "-t", f"{duration:.6f}", "-i", str(path)]
        start = duration - card.get("hold", 4.0)
        graph.append(f"[{idx}:v]format=rgba,fade=t=in:st={start:.3f}:d={card.get('fade', 1.2)}:alpha=1[t]")
        graph.append(f"[{prev}][t]overlay=0:0:format=auto,format=yuv420p[ti]")
        prev = "ti"
    if fade_out > 0:
        graph.append(f"[{prev}]fade=t=out:st={duration - fade_out:.3f}:d={fade_out}[v]")
    else:
        graph.append(f"[{prev}]null[v]")
    audio = len(manifest) + (1 if card else 0)
    inputs += ["-f", "lavfi", "-t", f"{duration:.6f}", "-i", "anullsrc=r=48000:cl=stereo"]
    final = out / "FractalXR-trailer.mp4"
    rate = re.fullmatch(r"(\d+(?:\.\d+)?)([kM])", args.maxrate)
    if not rate:
        raise ValueError("--maxrate looks like 16M or 8000k")
    bufsize = f"{float(rate.group(1)) * 2:g}{rate.group(2)}"
    (out / "filter-graph.txt").write_text(";\n".join(graph) + "\n")
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", *inputs,
         "-filter_complex", ";".join(graph), "-map", "[v]", "-map", f"{audio}:a:0",
         "-c:v", "libx264", "-preset", args.preset, "-crf", str(args.crf),
         "-maxrate", args.maxrate, "-bufsize", bufsize,
         "-profile:v", "high",
         "-pix_fmt", "yuv420p", *COLOUR, "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
         "-t", f"{duration:.6f}", "-movflags", "+faststart", str(final)])
    return final, duration, total, cuts


def contact_sheet(final, out, duration):
    """Frames every ~2.2 s of the finished cut, timestamped, under 1500 px wide."""
    sheet = out / "contact-sheet.jpg"
    step = max(1.0, duration / 28)
    run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(final),
         "-vf", f"fps=1/{step:.4f},scale=344:-2,tile=4x7:padding=6:color=0x101018",
         "-frames:v", "1", "-q:v", "3", str(sheet)])
    return sheet


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots", type=Path, default=PROJ / "data/trailer.json")
    parser.add_argument("--output", type=Path, default=PROJ / ".spike-out/trailer")
    parser.add_argument("--resolution", choices=["2560x1440", "1920x1080", "1280x720", "960x540"], default="2560x1440")
    parser.add_argument("--fps", type=int, choices=[30, 60], default=60)
    parser.add_argument("--only", help="comma-separated shot ids; renders those clips and filmstrips, no cut")
    parser.add_argument("--strips", action="store_true",
                        help="simulate every frame but save only six PNGs per shot, for judging motion fast")
    parser.add_argument("--reuse", action="store_true", help="keep existing clips that match the snapshot")
    parser.add_argument("--crf", type=int, default=18)
    parser.add_argument("--preset", default="slow")
    parser.add_argument("--maxrate", default="16M",
                        help="ceiling on the CRF encode; grainy flame shots otherwise run past 70 Mb/s")
    parser.add_argument("--timeout", type=int, default=1800)
    args = parser.parse_args()
    for command in ("ffmpeg", "ffprobe", "montage", "magick"):
        if not shutil.which(command):
            parser.error(f"missing {command}")
    data = json.loads(args.shots.read_text())
    shots = validate(data, args.fps)
    selected = set(args.only.split(",")) if args.only else {s["id"] for s in shots}
    if selected - {s["id"] for s in shots}:
        parser.error("--only contains an unknown shot id")
    full = not args.only and not args.strips
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Snapshot: an edit to the JSON during a render cannot change later shots of this run.
    snapshot = out / "render-shots.json"
    snapshot.write_text(json.dumps(data, indent=2) + "\n")
    cache = out / "clip-keys.json"
    keys = json.loads(cache.read_text()) if args.reuse and cache.exists() else {}
    godot = os.environ["GODOT"]
    base = [godot, "--xr-mode", "off", "--path", str(PROJ)]
    with (out / "import.log").open("w") as log:
        run(base + ["--headless", "--import"], stdout=log, stderr=subprocess.STDOUT, timeout=300)
    start = time.monotonic()
    manifest = []
    kind = "strip" if args.strips else "movie"
    for i, shot in enumerate(shots):
        if shot["id"] not in selected:
            continue
        # Transitions and post filters are applied in the cut, so editing them reuses the clip.
        clip_spec = {k: v for k, v in shot.items() if k not in ("transition", "post")}
        key = json.dumps([clip_spec, args.resolution, args.fps], sort_keys=True)
        clip = out / f"{shot['id']}.mp4"
        t0 = time.monotonic()
        if kind == "movie" and keys.get(shot["id"]) == key and clip.exists():
            print(f"TRAILER reusing {shot['id']}", flush=True)
            frames = frames_of(shot["duration"], args.fps)
            entry = dict(id=shot["id"], mode=shot["mode"], preset=shot["preset"], frames=frames,
                         duration=frames / args.fps, reused=True)
        else:
            print(f"TRAILER rendering {shot['id']} {shot['mode']} / {shot['preset']}", flush=True)
            entry = render_shot(base, snapshot, i, shot, args, out, kind)
            if kind == "movie":
                keys[shot["id"]] = key
                cache.write_text(json.dumps(keys, indent=1) + "\n")
        entry["wall_seconds"] = round(time.monotonic() - t0, 2)
        manifest.append(entry)
    report = dict(resolution=args.resolution, fps=args.fps, shots=manifest)
    if args.strips:
        strip_sheet(out, manifest, "strips.jpg")
    else:
        clip_filmstrips(out, manifest, args.fps)
    if full:
        final, duration, frames, cuts = assemble(data, shots, manifest, out, args)
        info = probe(final)
        (out / "ffprobe.json").write_text(json.dumps(info, indent=2) + "\n")
        video = next(s for s in info["streams"] if s["codec_type"] == "video")
        audio = next(s for s in info["streams"] if s["codec_type"] == "audio")
        width, height = map(int, args.resolution.split("x"))
        if (video["codec_name"] != "h264" or audio["codec_name"] != "aac"
                or (video["width"], video["height"]) != (width, height)
                or int(video["nb_read_frames"]) != frames
                or video["r_frame_rate"] != f"{args.fps}/1"
                or abs(float(info["format"]["duration"]) - duration) > 0.05):
            raise RuntimeError("final media validation failed")
        if not 30 <= duration <= 120:
            raise RuntimeError(f"a store trailer must last 30 to 120 seconds, this is {duration:.2f}")
        if {s["mode"] for s in manifest} != MODES:
            raise RuntimeError("a full cut must include all five modes")
        sheet = contact_sheet(final, out, duration)
        report.update(duration=round(duration, 3), frames=frames, cuts=cuts,
                      bytes=final.stat().st_size, contact_sheet=str(sheet))
    report["wall_seconds"] = round(time.monotonic() - start, 2)
    (out / "render-report.json").write_text(json.dumps(report, indent=2) + "\n")
    tail = f" duration={report['duration']:.2f}s size={report['bytes']}" if full else ""
    print(f"TRAILER PASS shots={len(manifest)}{tail} wall={report['wall_seconds']:.2f}s output={out}")


if __name__ == "__main__":
    main()
