# idtracker-local

This project helps you run animal tracking on videos using [idtracker.ai](https://idtracker.ai). It handles the repetitive work of running tracking jobs one after another, keeping track of which ones have finished, and organising the output files - so you can focus on the science.

Everything is run through **Pixi**, which manages all the software dependencies for you. You do not need to install Python, PyTorch, or idtracker.ai separately.

---

## Before you start

Make sure you have [Pixi](https://prefix.dev/docs/pixi/overview) installed. Once it is installed, open a terminal in this project folder and run:

```
pixi install
```

This will download and install everything the project needs. You only need to do this once.

---

## The workflow

The typical workflow has three phases: **preparing**, **tracking**, and **collecting results**.

### 1. Preparing a video

Before you configure tracking for a video, run:

```
pixi run gui
```

This opens a file browser where you can select your video. The script will then:

- Create a folder for that video inside `backgrounds/` - this is where you should save any background images you compute in idtracker.ai
- Create a folder for that video inside `settings/` - this is where you should save your settings file when you are done configuring
- Open idtracker.ai with that video preloaded

Inside idtracker.ai, find the right tracking interval, compute a background that works well, and tweak the rest of the settings. When you are happy, save the settings file into the `settings/<video_name>/` folder that was just created.

If a recording splits into multiple video files (e.g. `-00`, `-01`, `-02`), or if lighting conditions change within a recording (e.g. day and night), you can create multiple settings files for the same video - just save them all into the same settings subfolder.

### 2. Running tracking

Once you have one or more settings files saved, run:

```
pixi run track
```

This will:

1. Scan the `settings/` folder for any new settings files and register them
2. Fix any path issues in the settings files automatically
3. Run idtracker.ai for each registered job, one at a time
4. Save the results into the `sessions/` folder
5. Update the tracking log (`tracking_status.csv`) with the status of each job

You can leave this running overnight. If something goes wrong with one video, tracking will continue with the next one and the failed job will be marked so you can investigate later.

### 3. Collecting trajectory files

After tracking is complete, run:

```
pixi run copy
```

This copies the trajectory file (`trajectories.h5`) from each completed session into the `tracking/` folder, named after the session. If you later refine the trajectories using idtracker.ai's validator, re-running `copy` will overwrite the files with the latest version.

---

## Checking progress

To see the current status of all tracking jobs:

```
pixi run status
```

This shows a table with each settings file, the video it belongs to, and whether tracking is `pending`, `done`, `failed`, or `skip`.

You can also open `tracking_status.csv` directly in Excel or any spreadsheet application. To skip a job entirely, change its status to `skip` in the spreadsheet - `track` will then ignore it.

---

## All available commands

| Command | What it does |
|---|---|
| `pixi run gui` | Open file browser, create folders, launch idtracker.ai |
| `pixi run track` | Run all pending tracking jobs |
| `pixi run track-dryrun` | Test the tracking script without actually running idtracker.ai |
| `pixi run copy` | Copy trajectory files to the `tracking/` folder |
| `pixi run status` | Show the current status of all jobs |
| `pixi run fix-paths` | Fix path issues in settings files (also runs automatically before tracking) |
| `pixi run check-gpu` | Check whether PyTorch can see your GPU |
| `pixi run docs` | Show this documentation in the terminal |

---

## Folder structure

```
idtracker-local/
|-- backgrounds/
|   +-- <video_name>/        # Save background images here
|-- settings/
|   +-- <video_name>/        # Save settings .toml files here
|-- sessions/                # idtracker.ai output (created automatically)
|   +-- session_<n>/
|-- tracking/                # Trajectory .h5 files (created by `copy`)
|-- tracking_status.csv      # Log of all tracking jobs
|-- track.nu                 # The tracking script
+-- pixi.toml                # Project configuration
```

---

## Troubleshooting

**Tracking says "Video file not found"**

This usually means the path to the video in the settings file has been saved incorrectly. Run `pixi run fix-paths` and try again. If the problem persists, re-open the video with `pixi run gui` and re-save the settings file.

**A job is marked as `failed` but I want to retry it**

You do not need to change anything - `track` automatically retries all `failed` jobs. Just run `pixi run track` again.

**I want to skip a job**

Open `tracking_status.csv` and change the status of that row to `skip`. The job will then be ignored by `track`.

**Tracking is running on CPU instead of GPU**

Run `pixi run check-gpu` to verify whether PyTorch can see your GPU. If it cannot, check that your GPU drivers are up to date.