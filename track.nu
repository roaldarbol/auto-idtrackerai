#!/usr/bin/env nu

# ---------------------------------------------------------------------------
# Constants - edit these if your folder structure differs
# ---------------------------------------------------------------------------
const TRACKING_CSV = "tracking_status.csv"
const SESSIONS_DIR = "sessions"
const TRACKING_DIR = "tracking"
const BACKGROUNDS_DIR = "backgrounds"
const SETTINGS_DIR = "settings"
const LOGS_DIR = "logs"

def main [] {
    print "Usage: track.nu <subcommand>"
    print "Subcommands: gui, init, track, fix-paths, copy, status"
}

# ---------------------------------------------------------------------------
# Helpers - extract datetime and part index from video filenames
# Expected format: YYYYMMDD-HHMMSS-CODEC-NN (e.g. 20260204-180700-H264-01)
# Returns empty string if pattern is not found
# ---------------------------------------------------------------------------
def extract_datetime [filename: string] {
    let matches = ($filename | parse --regex '(?P<dt>\d{8}-\d{6})')
    if ($matches | is-empty) { "" } else { $matches | first | get dt }
}

def extract_part [filename: string] {
    let matches = ($filename | parse --regex '-(?P<part>\d{2})\.\w+$')
    if ($matches | is-empty) { "" } else { $matches | first | get part }
}

# ---------------------------------------------------------------------------
# gui - open a file dialog, create background and settings subfolders for the
# selected video, then launch idtrackerai with that video preloaded
# ---------------------------------------------------------------------------
def "main gui" [] {
    let video_path = (powershell -Command "
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Video files (*.mp4;*.avi;*.mov;*.mkv)|*.mp4;*.avi;*.mov;*.mkv|All files (*.*)|*.*'
        $dialog.Title = 'Select video file'
        if ($dialog.ShowDialog() -eq 'OK') { $dialog.FileName }
    " | str trim)

    if ($video_path | is-empty) {
        print "No file selected."
        return
    }

    let video_stem = ($video_path | path basename | path parse | get stem)
    mkdir ($BACKGROUNDS_DIR | path join $video_stem)
    mkdir ($SETTINGS_DIR | path join $video_stem)
    print $"Created folders for ($video_stem)"
    print "Opening idtrackerai..."
    run-external "idtrackerai" "--video_paths" $video_path
}

# ---------------------------------------------------------------------------
# init - scan SETTINGS_DIR recursively for .toml files, read the video path
# from each, and register any new files in the tracking CSV
# Safe to re-run: only adds new entries, never modifies existing ones
# ---------------------------------------------------------------------------
def "main init" [] {
    let files = (glob $"($SETTINGS_DIR)/**/*.toml")

    if ($files | is-empty) {
        print $"No .toml files found in ($SETTINGS_DIR)"
        return
    }

    let existing = if ($TRACKING_CSV | path exists) {
        open $TRACKING_CSV | get settings_file
    } else {
        []
    }

    let new_rows = (
        $files
        | where { |f| not ($f in $existing) }
        | each { |f|
            let settings = (open $f)
            let video_stem = if ("video_paths" in ($settings | columns)) {
                $settings.video_paths | first | path basename | path parse | get stem
            } else {
                ""
            }

            {
                settings_file: $f,
                video: $video_stem,
                datetime: (extract_datetime $video_stem),
                part: (extract_part $video_stem),
                status: "pending",
                session_folder: "",
                timestamp: "",
                notes: ""
            }
        }
    )

    if ($new_rows | is-empty) {
        print "No new settings files found."
        return
    }

    let all_rows = if ($TRACKING_CSV | path exists) {
        open $TRACKING_CSV | append $new_rows
    } else {
        $new_rows
    }

    let count = ($new_rows | length)
    $all_rows | save --force $TRACKING_CSV
    print $"Added ($count) new settings files to ($TRACKING_CSV)."
}

# ---------------------------------------------------------------------------
# track - run idtrackerai for all pending/failed jobs in the CSV
# Runs fix-paths first to correct double-escaped UNC paths in settings files
# Updates the CSV after each job so progress is preserved if the run is aborted
# Use --dry-run to test the script logic without invoking idtrackerai;
# the CSV is restored to its original state at the end of a dry run
# If a knowledge_transfer column is present and non-empty for a row, the
# --knowledge_transfer_folder flag is passed to idtrackerai for that job
# ---------------------------------------------------------------------------
def "main track" [--dry-run] {
    main fix-paths
    mkdir $SESSIONS_DIR
    mkdir $TRACKING_DIR
    mkdir $LOGS_DIR

    if not ($TRACKING_CSV | path exists) {
        print $"($TRACKING_CSV) not found. Run `init` first."
        return
    }

    let rows = open $TRACKING_CSV
    let pending = ($rows | where status in ["pending", "failed"])

    if ($pending | is-empty) {
        print "No pending files to run."
        return
    }

    let original_statuses = ($pending | select settings_file status)
    let count = ($pending | length)
    print $"Running ($count) pending jobs..."

    for row in $pending {
        print $"\nTracking: ($row.settings_file)"

        # Snapshot existing session folders before the job runs so we can
        # identify the new one by diffing afterwards. This is robust to
        # multiple settings files sharing the same video name, unlike any
        # approach that tries to match folder names after the fact.
        let folders_before = (
            try { ls $SESSIONS_DIR | get name } catch { [] }
        )

        # Use try/catch so Nushell does not treat a non-zero exit code from
        # idtrackerai as a fatal error, while still streaming output to the
        # terminal normally. $env.LAST_EXIT_CODE is set after the command.
        if $dry_run {
            print "(dry run - skipping idtrackerai)"
        } else {
            let has_kt = ("knowledge_transfer" in ($row | columns)) and ($row.knowledge_transfer | is-not-empty)
            if $has_kt {
                print $"Using knowledge transfer from: ($row.knowledge_transfer)"
                try { ^idtrackerai --load $row.settings_file --track --output_dir $SESSIONS_DIR --knowledge_transfer_folder $row.knowledge_transfer } catch {}
            } else {
                try { ^idtrackerai --load $row.settings_file --track --output_dir $SESSIONS_DIR } catch {}
            }
        }
        let ts = (date now | format date "%Y-%m-%dT%H:%M:%S")

        # The new session folder is whichever entry now exists that wasn't
        # there before. This is robust to multiple settings files sharing
        # the same video name and to idtrackerai's _1, _2 suffix scheme.
        let folders_after = (try { ls $SESSIONS_DIR | get name } catch { [] })
        let session_folder = if $dry_run {
            let base = ($SESSIONS_DIR | path join $"session_($row.video)")
            let n = ($folders_before | where { |f| $f =~ $"session_($row.video)" } | length)
            if $n == 0 { $base } else { $"($base)_($n)" }
        } else {
            let new_folders = ($folders_after | where { |f| not ($f in $folders_before) })
            if ($new_folders | is-not-empty) { $new_folders | first } else { "" }
        }

        # idtrackerai exits with code 1 even on success, so we determine
        # status from the log content instead: a missing session folder or
        # a CRITICAL line means failure; absence of "Success" also means failure.
        let session_log = ($session_folder | path join "idtrackerai.log")
        let new_status = if $dry_run {
            "done"
        } else if ($session_folder | is-empty) {
            "failed"
        } else if not ($session_log | path exists) {
            "failed"
        } else {
            let log_content = (try { open $session_log --raw } catch { "" })
            if ($log_content | str contains "CRITICAL") {
                "failed"
            } else if not ($log_content | str contains "Success") {
                "failed"
            } else {
                "done"
            }
        }

        if ($session_folder | is-empty) {
            print $"FAILED: ($row.settings_file) - no session folder detected"
        } else if $new_status == "failed" {
            let session_name = ($session_folder | path basename)
            print $"FAILED: ($row.settings_file) - check logs/($session_name).log"
        } else {
            print $"Done: ($row.settings_file)"
        }

        # Copy the idtrackerai log before it gets overwritten by the next job.
        if (not $dry_run) and ($session_folder | is-not-empty) and ($session_log | path exists) {
            let session_name = ($session_folder | path basename)
            try {
                cp $session_log ($LOGS_DIR | path join $"($session_name).log")
            } catch { |e|
                print $"Warning: could not copy log for ($session_name): ($e.msg)"
            }
        }

        # Write after every job so progress is not lost if the run is interrupted.
        try {
            let updated = (
                open $TRACKING_CSV
                | each { |r|
                    if $r.settings_file == $row.settings_file {
                        $r | update status $new_status | update timestamp $ts | update session_folder $session_folder
                    } else {
                        $r
                    }
                }
            )
            $updated | save --force $TRACKING_CSV
        } catch { |e|
            print $"Warning: could not update ($TRACKING_CSV) for ($row.settings_file): ($e.msg)"
        }
    }

    if $dry_run {
        let restored = (
            open $TRACKING_CSV
            | each { |r|
                let original = ($original_statuses | where settings_file == $r.settings_file)
                if ($original | is-empty) {
                    $r
                } else {
                    $r | update status ($original | first | get status) | update timestamp "" | update session_folder ""
                }
            }
        )
        $restored | save --force $TRACKING_CSV
        print "\nDry run complete - CSV restored to original state."
    } else {
        print "\nAll jobs processed."
    }
}

# ---------------------------------------------------------------------------
# copy - copy trajectories.h5 from each completed session into TRACKING_DIR,
# named after the session folder. Always overwrites so re-running after
# validation refinements picks up the latest version
# ---------------------------------------------------------------------------
def "main copy" [] {
    mkdir $TRACKING_DIR

    if not ($TRACKING_CSV | path exists) {
        print $"($TRACKING_CSV) not found. Run `init` first."
        return
    }

    let rows = (open $TRACKING_CSV | where status == "done" | where { |r| ($r.session_folder | is-not-empty) })

    if ($rows | is-empty) {
        print "No completed sessions to copy trajectories from."
        return
    }

    for row in $rows {
        let session_name = ($row.session_folder | path basename)
        let h5_src = ($row.session_folder | path join "trajectories" "trajectories.h5")
        let h5_dst = ($TRACKING_DIR | path join $"($session_name).h5")

        if ($h5_src | path exists) {
            cp $h5_src $h5_dst
            print $"Copied: ($session_name).h5"
        } else {
            print $"Warning: trajectories.h5 not found for ($session_name)"
        }
    }

    print "\nTrajectory copy complete."
}

# ---------------------------------------------------------------------------
# status - print a summary of the tracking CSV
# ---------------------------------------------------------------------------
def "main status" [] {
    if not ($TRACKING_CSV | path exists) {
        print $"($TRACKING_CSV) not found. Run `init` first."
        return
    }

    let rows = open $TRACKING_CSV
    print $rows
    print ""
    print $"Total:   ($rows | length)"
    print $"Pending: ($rows | where status == 'pending' | length)"
    print $"Done:    ($rows | where status == 'done' | length)"
    print $"Failed:  ($rows | where status == 'failed' | length)"
    print $"Skipped: ($rows | where status == 'skip' | length)"
}

# ---------------------------------------------------------------------------
# fix-paths - idtrackerai double-escapes backslashes in UNC paths when saving
# settings files (e.g. \\\\server becomes \\server after this fix).
# Called automatically by `track` before each run; safe to run manually too
# ---------------------------------------------------------------------------
def "main fix-paths" [] {
    let files = (glob $"($SETTINGS_DIR)/**/*.toml")

    if ($files | is-empty) {
        print "No settings files found."
        return
    }

    for f in $files {
        let content = (open $f --raw)
        let fixed = ($content | str replace --all '\\\\' '\\')
        if $fixed != $content {
            $fixed | save --force $f
            print $"Fixed paths in: ($f)"
        }
    }

    print "Path fix complete."
}
