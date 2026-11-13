#!/usr/bin/env python3
"""Render editable shots through Godot Movie Maker, then trim and join exact frames."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


PROJ = Path(os.environ["PROJ"])


def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-count_frames", "-show_streams", "-show_format",
        "-of", "json", str(path)]))


def validate(data, fps):
    shots = data["shots"]
    if not shots:
        raise ValueError("empty shot list")
    ids = set()
    for s in shots:
        if not re.fullmatch(r"[a-z0-9_-]+", s["id"]) or s["id"] in ids:
            raise ValueError("shot ids must be unique safe filenames")
        ids.add(s["id"])
        if s["mode"] not in {"FLAME", "BULB", "GROUND", "TREE", "IFS"}:
            raise ValueError(f"unknown mode in {s['id']}")
        if not isinstance(s["preset"], str) or not s["preset"]:
            raise ValueError("each shot needs a preset name")
        if not isinstance(s.get("point_style", 0), int) or not 0 <= s.get("point_style", 0) <= 3:
            raise ValueError("point_style must be an app POINT index from 0 to 3")
        if not 0 < s["duration"] <= 120 or not 10 <= s["fov"] <= 110:
            raise ValueError("invalid duration or vertical FOV")
        if math.floor(s["duration"] * fps + 0.5) < 1:
            raise ValueError("duration must contain at least one frame")
        for pose in (s["camera_start"], s["camera_end"]):
            for key in ("position", "look_at"):
                if len(pose[key]) != 3 or not all(math.isfinite(v) for v in pose[key]):
                    raise ValueError("poses need three finite coordinates")
            delta = [a - b for a, b in zip(pose["position"], pose["look_at"])]
            if delta[0] ** 2 + delta[2] ** 2 < 1e-8:
                raise ValueError("look_at must not be vertical or coincide with the camera")
        if s["mode"] == "GROUND":
            if len(s["ground_centre"]) != 2 or not s["ground_wpu"] > 0:
                raise ValueError("GROUND needs a centre and positive world metres per fractal unit")
        for key, values in s.get("animation", {}).items():
            if key not in {"colour_cycle", "ifs_depth"}:
                raise ValueError(f"unsupported animation {key}")
            if len(values) != 2 or not all(math.isfinite(v) for v in values):
                raise ValueError("animation needs finite start and end values")
            if key == "ifs_depth" and s["mode"] != "IFS":
                raise ValueError("ifs_depth requires IFS mode")
    return shots


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--shots", type=Path, default=PROJ / "data/trailer.json")
    parser.add_argument("--output", type=Path, default=PROJ / ".spike-out/trailer")
    parser.add_argument("--resolution", choices=["2560x1440", "1920x1080", "960x540"], default="2560x1440")
    parser.add_argument("--fps", type=int, choices=[30, 60], default=60)
    parser.add_argument("--only", help="comma-separated shot ids, useful for the IFS re-render")
    parser.add_argument("--stills", action="store_true", help="midpoint PNGs only, for selecting views")
    parser.add_argument("--keep-raw", action="store_true", help="keep Movie Maker startup AVI files")
    args = parser.parse_args()
    for command in ("ffmpeg", "ffprobe", "montage"):
        if not shutil.which(command):
            parser.error(f"missing {command}")
    data = json.loads(args.shots.read_text())
    shots = validate(data, args.fps)
    selected = set(args.only.split(",")) if args.only else {s["id"] for s in shots}
    if selected - {s["id"] for s in shots}:
        parser.error("--only contains an unknown shot id")
    if not args.stills and args.resolution == "960x540":
        parser.error("use at least 1920x1080 for a movie; 960x540 is for --stills")
    if not args.only and not args.stills:
        if not 30 <= sum(s["duration"] for s in shots) <= 120:
            parser.error("a store trailer must last 30 to 120 seconds")
        if {s["mode"] for s in shots} != {"FLAME", "BULB", "GROUND", "TREE", "IFS"}:
            parser.error("a full cut must include all five modes")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    # Snapshot prevents an edit during rendering from changing later shots in this run.
    snapshot = out / "render-shots.json"
    snapshot.write_text(json.dumps(data, indent=2) + "\n")
    godot = os.environ["GODOT"]
    base = [godot, "--xr-mode", "off", "--path", str(PROJ)]
    with (out / "import.log").open("w") as log:
        run(base + ["--headless", "--import"], stdout=log, stderr=subprocess.STDOUT, timeout=180)
    start = time.monotonic()
    manifest = []
    for i, shot in enumerate(shots):
        name = shot["id"]
        if name not in selected:
            continue
        print(f"TRAILER rendering {name} {shot['mode']} / {shot['preset']}", flush=True)
        raw = out / f"{name}.avi"
        logpath = out / f"{name}.log"
        command = base + ["--rendering-method", "mobile", "--resolution", args.resolution,
                          "--position", "0,0", "--disable-vsync", "--fixed-fps", str(args.fps)]
        if not args.stills:
            command += ["--write-movie", str(raw)]
        command += ["--script", "tools/trailer.gd", "--", str(snapshot), str(i),
                    str(args.fps), str(out), "still" if args.stills else "movie"]
        shot_start = time.monotonic()
        # Movie Maker reads project viewport dimensions before the script starts.
        # --resolution changes only the window, so it cannot set movie dimensions.
        width, height = map(int, args.resolution.split("x"))
        override = PROJ / "override.cfg"
        with override.open("x") as config:
            config.write(f"[display]\nwindow/size/viewport_width={width}\nwindow/size/viewport_height={height}\n")
        try:
            with logpath.open("w") as log:
                # subprocess.run kills and reaps only this child on timeout.
                run(command, stdout=log, stderr=subprocess.STDOUT, timeout=900)
        finally:
            override.unlink()
        text = logpath.read_text(errors="replace")
        if "TRAILERSHOT PASS" not in text or re.search(r"SCRIPT ERROR|SHADER ERROR|Parse Error|TRAILERSHOT FAIL", text):
            raise RuntimeError(f"Godot failed, see {logpath}")
        png = out / f"{name}.png"
        if not png.exists():
            raise RuntimeError(f"missing contact frame {png}")
        frames = math.floor(shot["duration"] * args.fps + 0.5)
        entry = dict(id=name, mode=shot["mode"], preset=shot["preset"], frames=frames,
                     duration=frames / args.fps)
        if not args.stills:
            info = probe(raw)
            video = next(s for s in info["streams"] if s["codec_type"] == "video")
            total = int(video["nb_read_frames"])
            width, height = map(int, args.resolution.split("x"))
            if (video["width"], video["height"]) != (width, height) or total < frames:
                raise RuntimeError(f"wrong Movie Maker dimensions or frame count: {video}")
            clip = out / f"{name}.mp4"
            run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(raw),
                 "-vf", f"trim=start_frame={total - frames},setpts=PTS-STARTPTS",
                 "-an", "-c:v", "libx264", "-preset", "fast", "-crf", "18",
                 "-pix_fmt", "yuv420p", "-fps_mode", "passthrough", str(clip)])
            trimmed = next(s for s in probe(clip)["streams"] if s["codec_type"] == "video")
            if int(trimmed["nb_read_frames"]) != frames:
                raise RuntimeError(f"wrong trimmed frame count for {name}")
            entry["warmup_frames"] = total - frames
            if not args.keep_raw:
                raw.unlink()
        entry["wall_seconds"] = round(time.monotonic() - shot_start, 2)
        manifest.append(entry)
    # macOS ships this font even when ImageMagick has no named font registry.
    montage = ["montage", "-font", "/System/Library/Fonts/Supplemental/Arial.ttf",
               "-background", "#101018", "-fill", "white", "-pointsize", "16"]
    for entry in manifest:
        montage += ["-label", f"{entry['id']}  {entry['mode']} / {entry['preset']}", str(out / f"{entry['id']}.png")]
    montage += ["-geometry", "480x270+8+12", "-tile", "4x", str(out / "contact-sheet.jpg")]
    run(montage)
    duration = sum(s["duration"] for s in manifest)
    if not args.stills:
        listing = out / "concat.txt"
        listing.write_text("".join(f"file '{s['id']}.mp4'\n" for s in manifest))
        final = out / "FractalXR-trailer.mp4"
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
             "-i", str(listing), "-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo",
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
             "-t", str(duration), "-movflags", "+faststart", str(final)])
        final_info = probe(final)
        (out / "ffprobe.json").write_text(json.dumps(final_info, indent=2) + "\n")
        video = next(s for s in final_info["streams"] if s["codec_type"] == "video")
        audio = next(s for s in final_info["streams"] if s["codec_type"] == "audio")
        if (video["codec_name"] != "h264" or audio["codec_name"] != "aac"
                or int(video["nb_read_frames"]) != sum(s["frames"] for s in manifest)
                or video["r_frame_rate"] != f"{args.fps}/1"
                or abs(float(final_info["format"]["duration"]) - duration) > 0.05):
            raise RuntimeError("final media validation failed")
    report = dict(resolution=args.resolution, fps=args.fps, duration=duration,
                  wall_seconds=round(time.monotonic() - start, 2), stills=args.stills, shots=manifest)
    (out / "render-report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"TRAILER PASS shots={len(manifest)} duration={duration:.2f}s wall={report['wall_seconds']:.2f}s output={out}")


if __name__ == "__main__":
    main()
