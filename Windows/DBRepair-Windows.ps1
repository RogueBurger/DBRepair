#########################################################################
# Database check and repair utility script for Plex Media Server        #
#                                                                       #
#########################################################################

$DBRepairVersion = 'v1.02.01'

class DBRepair {
    [DBRepairOptions] $Options

    [string] $PlexDBDir # Path to Plex's Databases directory
    [string] $PlexCache # Path to the PhotoTranscoder directory
    [string] $PlexSQL   # Path to 'Plex SQLite.exe'
    [string] $Timestamp # Timestamp used for temporary database files
    [string] $LogFile   # Path of our log file
    [string] $Version   # Current script version
    [string] $Stage     # Current stage of the script (e.g. "Auto", "Prune", etc.)
    [bool]   $IsError   # Whether we're currently in an error state
    [string] $BaseName = "com.plexapp.plugins.library"
    [string] $MainDB = "com.plexapp.plugins.library.db"
    [string] $BlobsDB = "com.plexapp.plugins.library.blobs.db"

    # Persistent timestamped-backup safety net (mirrors DBRepair.sh SetLast/RestoreSaved)
    [string] $LastName      # Name of the last successful undoable operation
    [string] $LastTimestamp # Timestamp of the backup taken before that operation

    # Free-space pre-check reporting (set by FreeSpaceAvailable)
    [int]    $SpaceNeeded    # MB needed for a destructive operation
    [int]    $SpaceAvailable # MB available on the database volume (-1 = unknown)

    # Database health flags (set by CheckDatabases, reported by status)
    [bool]   $CheckedDB  # Whether the databases have been integrity-checked this session
    [bool]   $DBDamaged  # Whether the last integrity check found damage

    # FTS (Full-Text Search) index health flags (tracked separately - FTS can be damaged
    # even when PRAGMA integrity_check passes)
    [bool]   $CheckedFTS # Whether the FTS indexes have been checked this session
    [bool]   $FTSDamaged # Whether the last FTS check found damage

    DBRepair($Arguments, $Version) {
        $this.Options = [DBRepairOptions]::new()
        $this.Version = $Version
        $this.IsError = $false
        $this.SetLast("", "")
        $Commands = $this.PreprocessArgs($Arguments)
        if ($null -eq $Commands) {
            return
        }

        if (!$this.Init()) {
            Write-Host "Unable to initialize script, cannot continue."
            return
        }

        $this.PrintHeader($true)
        $this.MainLoop($Commands)
    }

    [void] PrintHeader([boolean] $WriteToLog) {
        $OS = [System.Environment]::OSVersion.Version
        if ($WriteToLog) {
            $this.WriteLog("============================================================")
            $this.WriteLog("Session start: Host is Windows $($OS.Major) (Build $($OS.Build))")
        }

        Write-Host "`n"
        Write-Host "       Database Repair Utility for Plex Media Server (Windows $($OS.Major), Build $($OS.Build))"
        Write-Host "                                 Version $($this.Version)                                "
        Write-Host
    }

    [void] PrintHelp() {
        # -Help doesn't write to the log, since our log file path isn't set.
        $this.PrintHeader($false)
        Write-Host "When run without arguments, starts an interactive session that displays available options"
        Write-Host "and lets you select the operations you want to perform. Or, to run tasks automatically,"
        Write-Host "provide them directly to the script, e.g. '.\DBRepair-Windows.ps1 Stop Prune Start Exit'"
        Write-Host
        $this.PrintOptions("Main Options")
        Write-Host
        Write-Host "Extra Options - These can only be specified once (last one wins)"
        Write-Host
        Write-Host " -CacheAge [int]  - The date cutoff for pruned images. Defaults to pruning images over 30"
        Write-Host "                    days old."
        Write-Host
    }

    [void] PrintMenu() {
        $this.PrintOptions("Select")
    }

    [void] PrintOptions([string]$Header) {
        # NOTE: While Windows only supports a subset of DBRepair.sh's features, keep the command
        # numbers the same as we attempt to reach feature parity
        Write-Host
        Write-Host $Header
        Write-Host
        Write-Host "  1 - 'stop'      - Stop PMS."
        Write-Host "  2 - 'automatic' - Check, Repair/Optimize, Reindex, and FTS rebuild in one step."
        Write-Host "  3 - 'check'     - Perform integrity check of databases."
        Write-Host "  4 - 'vacuum'    - Remove empty space from databases without optimizing."
        Write-Host "  5 - 'repair'    - Repair/Optimize databases."
        Write-Host "  6 - 'reindex'   - Rebuild database indexes."
        Write-Host
        Write-Host "  7 - 'start'     - Start PMS"
        Write-Host
        Write-Host " 10 - 'show'      - Show logfile."
        Write-Host " 11 - 'status'    - Report status of PMS (run-state and databases)."
        Write-Host " 12 - 'undo'      - Undo last successful command."
        Write-Host
        Write-Host " 21 - 'prune'     - Prune (remove) old image files (jpeg,jpg,png) from PhotoTranscoder cache."
        if ($this.Options.IgnoreErrors) {
            Write-Host " 42 - 'honor'     - Honor all database errors."
        } else {
            Write-Host " 42 - 'ignore'    - Ignore duplicate/constraint errors."
        }
        Write-Host
        Write-Host " 98 - 'quit'      - Quit immediately.  Keep all temporary files."
        Write-Host " 99   'exit'      - Exit with cleanup options."
        Write-Host
        Write-Host "      'menu x'    - Show this menu in interactive mode, where x is on/off/yes/no"
    }

    # Do initial parsing of arguments that aren't part of the loop, returning
    # the list of arguments that _should_ be processed in the loop.
    #
    # E.g. given "Stop Prune CacheAge 20 Start", this function will set the CacheAge
    # to 20, and return "Stop Prune Start"
    [System.Collections.ArrayList] PreprocessArgs([string[]] $Arguments) {
        $FinalArgs = [System.Collections.ArrayList]::new()
        for ($i = 0; $i -lt $Arguments.Count; ++$i) {
            switch -Regex ($Arguments[$i]) {
                '^-?(H(elp)?|\?)$' {
                    if ($Arguments.Count -gt 1) {
                        Write-Warning "Found -Help, ignoring extra arguments"
                    }

                    $this.PrintHelp()
                    return $null
                }
                '^-?CacheAge$' {
                    if ($i -eq $Arguments.Count - 1) {
                        Write-Warning "Found -CacheAge argument, but no value. Using default of 30 days"
                        Break
                    }

                    ++$i
                    $Age = $Arguments[$i]
                    if (!($Age -match "^\d+$")) {
                        Write-Warning "Invalid -CacheAge value '$Age'. Using default of 30 days"
                        Break
                    }

                    $this.Options.CacheAge = [int]$Age
                }

                Default { $FinalArgs.Add($_) }
            }
        }

        return $FinalArgs
    }

    # Setup variables required for this utility to work.
    [bool] Init() {
        $this.Timestamp = Get-Date -Format HH-mm-ss

        $AppData = $this.GetAppDataDir()
        $Success = $this.GetPlexDBDir($AppData) -and $this.GetPlexSQL() -and $this.GetPhotoTranscoderDir($AppData)
        if ($Success) {
            $this.LogFile = Join-Path $this.PlexDBDir -ChildPath "DBRepair.log"
        }

        return $Success
    }

    # Core routine that loops over all provided commands and executes them in order.
    [void] MainLoop([System.Collections.ArrayList] $Arguments) {
        $this.Options.Scripted = $Arguments.Count -ne 0
        $i = 0
        $Argc = $Arguments.Count
        $NullInput = 0
        $EOFExit = $false
        while ($true) {
            $Choice = $null
            if ($this.Options.Scripted) {
                if ($i -eq $Argc) {
                    $Choice = "exit"
                } else {
                    $Choice = $Arguments[$i++]
                }
            } else {
                if ($this.Options.ShowMenu) {
                    $this.PrintMenu()
                }

                Write-Host
                $Choice = Read-Host "Enter command # -or- command name (4 char min)"
                if ($Choice -eq "") {
                    ++$NullInput
                    if ($NullInput -eq 5) {
                        $this.Output("Unexpected EOF / End of command line options. Exiting. Keeping temp files. ")
                        $Choice = "exit"
                        $EOFExit =  $true
                    } else {
                        if ($NullInput -eq 4) {
                            Write-Warning "Next empty command exits as EOF.  "
                        }

                        continue
                    }
                } else {
                    $NullInput = 0
                }
            }

            # Update timestamp
            $this.Timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'

            switch -Regex ($Choice) {
                "^(1|stop)$" { $this.DoStop() }
                "^(2|autom?a?t?i?c?)$" {
                    $this.SetStage("Auto")
                    $this.IsError = !$this.DoAutomatic()
                }
                "^(3|chec(k)?)$" {
                    $this.SetStage("Check")
                    $this.DoCheck()
                }
                "^(4|vacu(um?)?)$" {
                    $this.SetStage("Vacuum")
                    $this.IsError = !$this.DoVacuum()
                }
                "^(5|repa(ir?)?)$" {
                    $this.SetStage("Repair")
                    $this.IsError = !$this.DoRepair()
                }
                "^(6|rein(dex?)?|inde(x)?)$" {
                    $this.SetStage("Reindex")
                    $this.IsError = !$this.DoReindex()
                }
                "^(7|start?)$" { $this.StartPMS() }
                "^(10|show)$" { $this.DoShow() }
                "^(11|stat(us?)?)$" { $this.DoStatus() }
                "^(12|undo)$" {
                    $this.SetStage("Undo")
                    $this.DoUndo()
                }
                "^(21|(prune?|remov?e?))$" {
                    $this.SetStage("Prune")
                    $this.PrunePhotoTranscoderCache()
                }
                "^(42|ignor?e?|honor?)$" {
                    if (($this.Options.IgnoreErrors -and ($Choice[0] -eq 'i')) -or (!$this.Options.IgnoreErrors -and ($Choice[0] -eq 'h'))) {
                        Write-Host "Honor/Ignore setting unchanged."
                        Break
                    }

                    $this.Options.IgnoreErrors = !$this.Options.IgnoreErrors
                    $msg = if ($this.Options.IgnoreErrors) { "Ignoring database errors." } else { "Honoring database errors." }
                    $this.WriteOutputLog($msg)
                }
                "^(98|quit)$" {
                    $this.Output("Retaining all temporary work files.")
                    $this.WriteLog("Exit    - Retain temp files.")
                    $this.WriteEnd()
                    return
                }
                "^(99|exit)$" {
                    if ($EOFExit) {
                        $this.Output("Unexpected exit command. Keeping all temporary work files.")
                        $this.WriteLog("EOFExit  - Retain temp files.")
                        return
                    }

                    # If our last DB operation failed, we don't want to automatically delete
                    # temporary files when in scripted mode.
                    if ($this.IsError -and $this.Options.Scripted) {
                        $this.Output("Exiting with errors. Keeping all temporary work files.")
                        $this.WriteLog("Exit    - Retain temp files.")
                        return
                    }

                    $this.CleanDBTemp(!$this.Options.Scripted)
                    $this.WriteEnd()
                    return
                }
                "^menu\b" {
                    $Match = $Choice -match "^menu\s+(on|off|yes|no)"
                    if (!$Match) {
                        $this.OutputWarn("Invalid 'menu' format. Expected 'menu on/off/yes/no', got '$Choice'")
                        Break
                    }

                    $TurnOn = ($Matches.1 -eq 'on') -or ($Matches.1 -eq 'yes');
                    $this.Options.ShowMenu = $TurnOn
                    if (!$TurnOn) {
                        Write-Host "Menu off: Reenable with 'menu on' command"
                    }
                }
                Default {
                    $this.OutputWarn("Unknown Command: '$Choice'")
                    $this.WriteLog("Unknown command:   '$Choice'")
                }
            }
        }
    }

    # Attempt to stop Plex Media Server if it's running
    [void] DoStop() {
        $this.WriteLog("Stop    - START")
        $PMS = $this.GetPMS()
        if ($null -eq $PMS) {
            $this.Output("PMS already stopped.")
            return
        }

        $this.Output("Stopping PMS.")

        # Plex doesn't respond to CloseMainWindow because it doesn't have a window,
        # and Stop-Process does a forced exit of the process, so use taskkill to ask
        # PMS to close nicely, and bail if that doesn't work.
        $ErrorText = $null
        Invoke-Expression "taskkill /im ""Plex Media Server.exe""" 2>$null -ErrorVariable ErrorText
        if ($ErrorText) {
            $this.WriteOutputLogWarn("Failed to send terminate signal to PMS, please stop manually.")
            $this.WriteOutputLogWarn($ErrorText -join "`n")
            return
        }

        $PMS.WaitForExit(30000) *>$null # Wait at most 30 seconds for PMS to close. If it still hasn't by then, bail.
        if ($PMS.HasExited) {
            $this.WriteLog("Stop    - PASS")
            $this.Output("Stopped PMS.")
            return
        }

        $this.OutputWarn("Could not stop PMS. PMS did not shutdown within 30 second limit.")
        $this.WriteLog("Stop    - FAIL (Timeout)")
    }

    # Start Plex Media Server if it isn't already running
    [void] StartPMS() {
        $this.WriteLog("Start   - START")
        if ($this.PMSRunning()) {
            $this.Output("Start not needed. PMS is running.")
            $this.WriteLog("Start   - PASS - PMS is already running")
            return
        }

        $PMS = Join-Path (Split-Path -Parent $this.PlexSQL) -ChildPath "Plex Media Server.exe"
        try {
            Start-Process $PMS -EA Stop
            $this.Output("Started PMS")
            $this.WriteLog("Start   - PASS")
        } catch {
            $Err = $Error -join "`n"
            $this.OutputWarn("Could not start PMS: $Err")
            $Error.Clear()
        }
    }

    # All-in-one database utility - Check, Repair/Optimize, then Reindex (mirrors DBRepair.sh 'automatic').
    # Aborts if the integrity check fails; damaged databases must be addressed with 'repair' or 'replace'.
    [bool] DoAutomatic() {
        $this.Output("Automatic Check, Repair/Optimize, Index started.")
        $this.WriteLog("Auto    - START")

        if ($this.PMSRunning()) {
            $this.WriteLog("Auto    - FAIL - PMS running")
            $this.OutputWarn("Unable to run automatic sequence.  PMS is running. Please stop PlexMediaServer.")
            return $false
        }

        if (!$this.FreeSpaceAvailable(3)) {
            $this.WriteLog("Auto    - FAIL - Insufficient free space")
            $this.OutputWarn("Unable to run automatic sequence.  Insufficient free space (need $($this.SpaceNeeded) MB, have $($this.SpaceAvailable) MB).")
            return $false
        }

        # Check (forced) - automatic only proceeds on healthy databases
        $this.SetStage("Check")
        if ($this.CheckDatabases($true)) {
            $this.WriteLog("Check   - PASS")
        } else {
            $this.WriteLog("Check   - FAIL")
            $this.OutputWarn("Databases are damaged. Automatic mode cannot continue.")
            $this.OutputWarn("Use 'repair' (5) to rebuild damaged databases, or 'replace' (9) to restore a backup.")
            return $false
        }

        # Repair / optimize
        $this.UpdateTimestamp()
        $this.SetStage("Repair")
        if (!$this.DoRepair()) {
            $this.WriteLog("Auto    - FAIL")
            $this.OutputWarn("Repair failed. Automatic mode cannot continue.")
            return $false
        }

        # Reindex (DoReindex also checks and rebuilds FTS as its final step)
        $this.UpdateTimestamp()
        $this.SetStage("Reindex")
        if (!$this.DoReindex()) {
            $this.WriteLog("Auto    - FAIL")
            $this.OutputWarn("Reindex failed. Automatic mode cannot continue.")
            return $false
        }

        $this.WriteLog("Auto    - COMPLETED")
        $this.Output("Automatic Check, Repair/Optimize, Index, & FTS check successful.")
        return $true
    }

    # Repair/optimize the databases: export each to SQL, import into a fresh DB, verify integrity,
    # then swap the rebuilt DBs into place while keeping a persistent timestamped backup (undoable).
    # Does not check integrity first - this is the command to use on a damaged database.
    [bool] DoRepair() {
        $this.Output("Repair/optimize of databases started.")
        $this.WriteLog($this.StageLog("START"))

        if (!$this.CheckPMS("repair")) { return $false }

        if (!$this.FreeSpaceAvailable(3)) {
            $this.OutputWarn("Insufficient free space to repair (need $($this.SpaceNeeded) MB, have $($this.SpaceAvailable) MB).")
            $this.WriteLog($this.StageLog("FAIL - Insufficient free space"))
            return $false
        }

        $DBTemp = $this.EnsureDBTemp()
        if (!$DBTemp) { return $false }

        $MainDBPath = Join-Path $this.PlexDBDir -ChildPath $this.MainDB
        $BlobsDBPath = Join-Path $this.PlexDBDir -ChildPath $this.BlobsDB
        if (!$this.FileExists($MainDBPath)) {
            $this.ExitDBMaintenance("Could not find $($this.MainDB) in database directory", $false)
            return $false
        }
        if (!$this.FileExists($BlobsDBPath)) {
            $this.ExitDBMaintenance("Could not find $($this.BlobsDB) in database directory", $false)
            return $false
        }

        # Export both databases to SQL files in the scratch directory
        $this.Output("Exporting Main DB")
        $MainDBSQL = Join-Path $DBTemp -ChildPath "library.sql_$($this.Timestamp)"
        if (!$this.ExportPlexDB($MainDBPath, $MainDBSQL)) { return $false }

        $this.Output("Exporting Blobs DB")
        $BlobsDBSQL = Join-Path $DBTemp -ChildPath "blobs.sql_$($this.Timestamp)"
        if (!$this.ExportPlexDB($BlobsDBPath, $BlobsDBSQL)) { return $false }

        $this.Output("Successfully exported the main and blobs databases. Proceeding to import into new database.")
        $this.WriteLog($this.StageLog("Export databases - PASS"))

        # Make sure Plex hasn't been started while we were exporting
        if (!$this.CheckPMS("export")) { return $false }

        # Import into fresh databases (scratch copies in dbtmp)
        $this.Output("Importing Main DB.")
        $MainDBImport = Join-Path $DBTemp -ChildPath "$($this.MainDB)-REPAIR-$($this.Timestamp)"
        if (!$this.ImportPlexDB($MainDBSQL, $MainDBImport)) { return $false }

        $this.Output("Importing Blobs DB.")
        $BlobsDBImport = Join-Path $DBTemp -ChildPath "$($this.BlobsDB)-REPAIR-$($this.Timestamp)"
        if (!$this.ImportPlexDB($BlobsDBSQL, $BlobsDBImport)) { return $false }

        $this.Output("Successfully imported databases.")
        $this.WriteLog($this.StageLog("Import - PASS"))

        # Verify the rebuilt databases before swapping them in
        $this.Output("Verifying databases integrity after importing.")
        if (!$this.IntegrityCheck($MainDBImport, "Main")) { return $false }
        $this.Output("Verification complete. PMS main database is OK.")
        $this.WriteLog($this.StageLog("Verify main database - PASS"))

        if (!$this.IntegrityCheck($BlobsDBImport, "Blobs")) { return $false }
        $this.Output("Verification complete. PMS blobs database is OK.")
        $this.WriteLog($this.StageLog("Verify blobs database - PASS"))

        if (!$this.CheckPMS("replace")) { return $false }

        # Swap: move the live DBs aside to a persistent timestamped backup, then install the rebuilt DBs.
        $this.WriteOutputLog("Backing up current databases and installing rebuilt databases.")
        try {
            $this.BackupLiveByMove()
            $this.MoveDatabase($MainDBImport, $MainDBPath, "install rebuilt Main DB")
            $this.MoveDatabase($BlobsDBImport, $BlobsDBPath, "install rebuilt Blobs DB")
        } catch {
            $Error.Clear()
            return $false
        }

        # The rebuilt databases were integrity-verified just above; record them as checked-healthy.
        $this.SetLast("Repair", $this.Timestamp)
        $this.CheckedDB = $true
        $this.DBDamaged = $false
        $this.ExitDBMaintenance("Repair/optimize completed.", $true)
        return $true
    }

    # Rebuild the database indexes (REINDEX). Requires healthy databases and makes an undoable backup.
    [bool] DoReindex() {
        $this.Output("Reindex of databases started.")
        $this.WriteLog($this.StageLog("START"))

        if (!$this.CheckPMS("reindex")) { return $false }

        if (!$this.FreeSpaceAvailable(3)) {
            $this.OutputWarn("Insufficient free space to reindex (need $($this.SpaceNeeded) MB, have $($this.SpaceAvailable) MB).")
            $this.WriteLog($this.StageLog("FAIL - Insufficient free space"))
            return $false
        }

        if (!$this.CheckDatabases($false)) {
            $this.OutputWarn("Databases are damaged. Reindex not available. Please repair or replace first.")
            $this.WriteLog($this.StageLog("FAIL - databases damaged"))
            return $false
        }

        if (!$this.MakeBackups()) {
            $this.WriteLog($this.StageLog("MakeBackup - FAIL"))
            return $false
        }
        $this.WriteLog($this.StageLog("MakeBackup - PASS"))

        $MainDBPath = Join-Path $this.PlexDBDir -ChildPath $this.MainDB
        $BlobsDBPath = Join-Path $this.PlexDBDir -ChildPath $this.BlobsDB

        $this.WriteOutputLog("Reindexing Main DB")
        if (!$this.RunSQLCommand("""$MainDBPath"" ""REINDEX;""", "Failed to reindex Main DB")) {
            $this.RestoreSaved($this.Timestamp)
            return $false
        }
        $this.WriteOutputLog("Reindexing Blobs DB")
        if (!$this.RunSQLCommand("""$BlobsDBPath"" ""REINDEX;""", "Failed to reindex Blobs DB")) {
            $this.RestoreSaved($this.Timestamp)
            return $false
        }

        $this.SetLast("Reindex", $this.Timestamp)
        $this.WriteOutputLog("Reindex complete.")
        $this.WriteLog($this.StageLog("PASS"))

        # Check FTS indexes and rebuild if damaged (does not affect reindex success)
        $this.Output("")
        $this.EnsureFTS() | Out-Null
        return $true
    }

    # Reclaim unused space in both databases (VACUUM). Requires healthy databases and makes an undoable backup.
    [bool] DoVacuum() {
        $this.Output("Vacuum of databases started.")
        $this.WriteLog($this.StageLog("START"))

        if (!$this.CheckPMS("vacuum")) { return $false }

        if (!$this.CheckDatabases($false)) {
            $this.OutputWarn("Databases are damaged. Vacuum not available. Please repair or replace first.")
            $this.WriteLog($this.StageLog("FAIL - databases damaged"))
            return $false
        }

        if (!$this.MakeBackups()) {
            $this.WriteLog($this.StageLog("MakeBackup - FAIL"))
            return $false
        }
        $this.WriteLog($this.StageLog("MakeBackup - PASS"))

        $MainDBPath = Join-Path $this.PlexDBDir -ChildPath $this.MainDB
        $BlobsDBPath = Join-Path $this.PlexDBDir -ChildPath $this.BlobsDB

        $StartSize = $this.GetSizeMB($MainDBPath)
        $this.WriteOutputLog("Vacuuming Main DB")
        if (!$this.RunSQLCommand("""$MainDBPath"" ""VACUUM;""", "Failed to vacuum Main DB")) {
            $this.RestoreSaved($this.Timestamp)
            return $false
        }
        $this.WriteOutputLog("Vacuumed Main DB (Size: $($StartSize)MB/$($this.GetSizeMB($MainDBPath))MB)")

        $StartSize = $this.GetSizeMB($BlobsDBPath)
        $this.WriteOutputLog("Vacuuming Blobs DB")
        if (!$this.RunSQLCommand("""$BlobsDBPath"" ""VACUUM;""", "Failed to vacuum Blobs DB")) {
            $this.RestoreSaved($this.Timestamp)
            return $false
        }
        $this.WriteOutputLog("Vacuumed Blobs DB (Size: $($StartSize)MB/$($this.GetSizeMB($BlobsDBPath))MB)")

        $this.SetLast("Vacuum", $this.Timestamp)
        $this.ExitDBMaintenance("Vacuum complete.", $true)
        return $true
    }

    # Integrity-check both databases and their FTS indexes (standalone 'check' command).
    [void] DoCheck() {
        $this.WriteLog($this.StageLog("START"))
        if (!$this.CheckPMS("check")) { return }

        if ($this.CheckDatabases($true)) {
            $this.WriteLog($this.StageLog("PASS"))
        } else {
            $this.WriteLog($this.StageLog("FAIL"))
            $this.Output("One or more databases are damaged. Use 'repair' (5) or 'replace' (9).")
        }

        # FTS indexes can be damaged even when the integrity check passes
        $this.Output("")
        if (!$this.CheckFTS()) {
            $this.Output("")
            $this.Output("NOTE: FTS indexes are damaged but the main database structure may be OK.")
            $this.Output("      Use 'reindex' (6) or 'automatic' (2) to rebuild.")
        }
    }

    # Report PMS run-state and database presence/size/health (standalone 'status' command).
    [void] DoStatus() {
        $this.Output("")
        $this.Output("Status report: $(Get-Date)")
        if ($this.PMSRunning()) {
            $this.Output("  PMS is running.")
        } else {
            $this.Output("  PMS is stopped.")
        }

        foreach ($db in @($this.MainDB, $this.BlobsDB)) {
            $path = Join-Path $this.PlexDBDir -ChildPath $db
            if ($this.FileExists($path)) {
                $this.Output("  $db - present ($($this.GetSizeMB($path)) MB)")
            } else {
                $this.Output("  $db - MISSING")
            }
        }

        if (!$this.CheckedDB) {
            $this.Output("  Databases are not checked. Status unknown.")
        } elseif (!$this.DBDamaged) {
            $this.Output("  Databases are OK.")
        } else {
            $this.Output("  Databases were checked and are damaged.")
        }

        if (!$this.CheckedFTS) {
            $this.Output("  FTS indexes are not checked. Status unknown.")
        } elseif (!$this.FTSDamaged) {
            $this.Output("  FTS indexes are OK.")
        } else {
            $this.Output("  FTS indexes are damaged.")
        }

        if ($this.LastTimestamp) {
            $this.Output("  Last undoable operation: $($this.LastName) ($($this.LastTimestamp))")
        } else {
            $this.Output("  No operation available to undo.")
        }
        $this.Output("")
    }

    # Print the contents of the tool's log file (standalone 'show' command).
    [void] DoShow() {
        if (!$this.FileExists($this.LogFile)) {
            $this.Output("No log file found at $($this.LogFile)")
            return
        }

        Write-Host "=================================================================================="
        Get-Content -Path $this.LogFile | ForEach-Object { Write-Host $_ }
        Write-Host "=================================================================================="
    }

    # Restore the databases to the state before the last successful operation (standalone 'undo' command).
    [void] DoUndo() {
        if (!$this.LastTimestamp) {
            $this.Output("Nothing to undo.")
            $this.WriteLog($this.StageLog("Nothing to undo"))
            return
        }

        if (!$this.CheckPMS("undo")) { return }

        Write-Host ""
        Write-Host "'Undo' restores the databases to the state prior to the last SUCCESSFUL action."
        Write-Host "Be advised: this reverts the last 'Repair', 'Reindex', or 'Vacuum'."
        Write-Host "WARNING: once Undo completes, there is nothing more to undo until another successful action."
        Write-Host ""

        $Proceed = $this.Options.Scripted -or $this.GetYesNo("Undo '$($this.LastName)' performed at timestamp '$($this.LastTimestamp)'")
        if (!$Proceed) {
            $this.Output("Undo cancelled.")
            return
        }

        $this.Output("Undoing $($this.LastName) ($($this.LastTimestamp))")
        $this.RestoreSaved($this.LastTimestamp)
        $this.Output("Undo complete.")
        $this.WriteLog($this.StageLog("Undo $($this.LastName), TimeStamp $($this.LastTimestamp)"))
        $this.SetLast("Undo", "")
        $this.CheckedDB = $false
        $this.CheckedFTS = $false
    }

    ### FTS (Full-Text Search) helpers (mirrors DBRepair.sh CheckFTS/DoFTSRebuild) ###

    # Query that lists FTS4 virtual tables, excluding their shadow tables.
    [string] FTSTableQuery() {
        return "SELECT name FROM sqlite_master WHERE type='table' AND sql LIKE '%fts4%'" +
            " AND name NOT LIKE '%_content' AND name NOT LIKE '%_segments'" +
            " AND name NOT LIKE '%_segdir' AND name NOT LIKE '%_stat'" +
            " AND name NOT LIKE '%_docsize' ORDER BY name;"
    }

    # Return the FTS4 table names in the given database (empty array if none or on error).
    [string[]] GetFTSTables([string] $DBPath) {
        $Result = ""
        if (!$this.TryRunSQL("""$DBPath"" ""$($this.FTSTableQuery())""", [ref]$Result)) { return @() }
        return @($Result) | ForEach-Object { "$_".Trim() } | Where-Object { $_ }
    }

    # Check FTS index integrity across both databases, updating CheckedFTS/FTSDamaged.
    # Returns $true if all FTS indexes are OK.
    [bool] CheckFTS() {
        $this.Output("Checking FTS (Full-Text Search) indexes")
        $FTSFail = $false

        foreach ($db in @(@($this.MainDB, ""), @($this.BlobsDB, " (blobs)"))) {
            $DBPath = Join-Path $this.PlexDBDir -ChildPath $db[0]
            $Label = $db[1]
            if (!$this.FileExists($DBPath)) { continue }

            $Tables = $this.GetFTSTables($DBPath)
            if ($Tables.Count -eq 0) {
                if (!$Label) { $this.Output("No FTS4 tables found in main database.") }
                continue
            }

            foreach ($Table in $Tables) {
                $Out = ""
                $OK = $this.TryRunSQL("""$DBPath"" ""INSERT INTO $Table($Table) VALUES('integrity-check');""", [ref]$Out)
                if ($OK -and !$Out) {
                    $this.Output("  FTS index '$Table'$Label - OK")
                    $this.WriteLog($this.StageLog("FTS Check: $Table - PASS"))
                } else {
                    $this.Output("  FTS index '$Table'$Label - DAMAGED")
                    if ($Out) { $this.Output("    Error: $Out") }
                    $this.WriteLog($this.StageLog("FTS Check: $Table - FAIL"))
                    $FTSFail = $true
                }
            }
        }

        $this.CheckedFTS = $true
        $this.FTSDamaged = $FTSFail
        if (!$FTSFail) {
            $this.Output("FTS integrity check complete. All FTS indexes OK.")
            $this.WriteLog($this.StageLog("FTS Check - PASS"))
        } else {
            $this.Output("FTS integrity check complete. One or more FTS indexes are DAMAGED.")
            $this.Output("Use 'reindex' (6) or 'automatic' (2) to rebuild.")
            $this.WriteLog($this.StageLog("FTS Check - FAIL"))
        }

        return !$FTSFail
    }

    # Rebuild the FTS indexes across both databases. Makes an undoable backup, restores it on failure.
    [bool] DoFTSRebuild() {
        $this.Output("FTS index rebuild started.")
        $this.WriteLog($this.StageLog("START"))

        if (!$this.CheckPMS("FTS rebuild")) { return $false }

        # FTS corruption can pass integrity_check, so a damaged main DB doesn't necessarily block us.
        if (!$this.CheckDatabases($false)) {
            $this.OutputWarn("Database integrity check failed.")
            $this.Output("FTS rebuild may still help if the corruption is isolated to FTS indexes.")
            if (!($this.Options.Scripted -or $this.GetYesNo("Continue with FTS rebuild anyway"))) {
                $this.Output("FTS rebuild cancelled.")
                return $false
            }
        }

        if (!$this.MakeBackups()) {
            $this.WriteLog($this.StageLog("MakeBackup - FAIL"))
            return $false
        }
        $this.WriteLog($this.StageLog("MakeBackup - PASS"))

        $Fail = $false
        foreach ($db in @(@($this.MainDB, ""), @($this.BlobsDB, " (blobs)"))) {
            $DBPath = Join-Path $this.PlexDBDir -ChildPath $db[0]
            $Label = $db[1]
            if (!$this.FileExists($DBPath)) { continue }

            $Tables = $this.GetFTSTables($DBPath)
            if ($Tables.Count -eq 0) { continue }

            foreach ($Table in $Tables) {
                $this.Output("  Rebuilding $Table$Label...")
                $Out = ""
                $OK = $this.TryRunSQL("""$DBPath"" ""INSERT INTO $Table($Table) VALUES('rebuild');""", [ref]$Out)
                if ($OK) {
                    $this.Output("    $Table rebuilt successfully.")
                    $this.WriteLog($this.StageLog("Rebuild$($Label): $Table - PASS"))
                } elseif ($this.Options.IgnoreErrors) {
                    $this.OutputWarn("Ignoring rebuild error for $Table$Label.")
                    $this.WriteLog($this.StageLog("Rebuild$($Label): $Table - IGNORED"))
                } else {
                    $this.Output("    $Table rebuild failed. $Out")
                    $this.WriteLog($this.StageLog("Rebuild$($Label): $Table - FAIL"))
                    $Fail = $true
                }
            }
        }

        if (!$Fail) {
            $this.SetLast("FTSRbld", $this.Timestamp)
            $this.FTSDamaged = $false
            $this.ExitDBMaintenance("FTS rebuild complete.", $true)
            return $true
        }

        $this.Output("Some FTS indexes failed to rebuild. Restoring backup.")
        $this.RestoreSaved($this.Timestamp)
        $this.WriteLog($this.StageLog("FAIL"))
        return $false
    }

    # Check the FTS indexes and rebuild them if damaged. Returns $true if FTS ends up healthy.
    # FTS failures do not fail the calling operation (the main DB work has already succeeded).
    [bool] EnsureFTS() {
        if ($this.CheckFTS()) { return $true }

        $this.Output("")
        $this.Output("FTS indexes are damaged. Attempting FTS rebuild...")
        $this.UpdateTimestamp()
        $this.SetStage("FTSRbld")
        if ($this.DoFTSRebuild()) {
            $this.Output("FTS rebuild successful.")
            return $true
        }

        $this.OutputWarn("FTS rebuild failed. You may need to run 'reindex' (6) manually.")
        return $false
    }

    # Return whether we can continue DB repair (i.e. whether PMS is running) at the given stage in the process.
    [bool] CheckPMS([string] $SubStage) {
        if ($this.PMSRunning()) {
            $SubMessage = if ($SubStage) { "during $SubStage" } else { "" }
            $this.WriteLog($this.StageLog("FAIL - PMS running $SubMessage"))
            $this.OutputWarn("Unable to run $($this.Stage.TrimEnd()).  PMS is running. Please stop PlexMediaServer.")
            return $false
        }

        return $true
    }

    # Try to move the source file to the destination. If it fails, attempt to find
    # open file handles (requires handle.exe on PATH) and throw.
    [void] MoveDatabase([string] $Source, [string] $Destination, [string] $FriendlyString) {
        $MoveError = $null
        Move-Item -Path $Source -Destination $Destination -ErrorVariable MoveError *>$null
        if ($MoveError) {
            $this.ExitDBMaintenance("Unable to $($FriendlyString): $MoveError", $false)
            throw "Unable to move database"
        }
    }

    # Attempts to prune PhotoTranscoder images that are older than the specified date cutoff (30 days by default)
    [void] PrunePhotoTranscoderCache() {
        $this.WriteLog($this.StageLog("START"))
        if ($this.PMSRunning()) {
            $this.OutputWarn("Unable to prune Phototranscoder cache. PMS is running.")
            $this.WriteLog($this.StageLog("FAIL - PMS running"))
            return
        }

        $Cutoff = $this.Options.CacheAge
        $ShouldPrune = $this.Options.Scripted
        if (!$ShouldPrune) {
            $this.Output("Counting how many files are more than $Cutoff days old")
            $CacheResult = $this.CheckPhotoTranscoderCache($true)
            $Prunable = $CacheResult.PrunableFiles
            $SpaceSaved = $CacheResult.SpaceSavings

            if ($Prunable -eq 0) {
                $this.Output("No files found to prune.")
                $this.WriteLog($this.StageLog("PASS (no files found to prune)"))
                return
            }

            $ShouldPrune = $this.GetYesNo("OK to prune $Prunable files ($SpaceSaved)")
        }

        if ($ShouldPrune) {
            $this.Output("Pruning started.")
            $PruneResult = $this.CheckPhotoTranscoderCache($false)
            $Pruned = $PruneResult.PrunableFiles
            $Total = $PruneResult.TotalFiles
            $Saved = $PruneResult.SpaceSavings
            $this.WriteOutputLog($this.StageLog("Removed $Pruned files over $Cutoff days old ($Saved), out of $Total total files"))
            $this.Output("Pruning completed.")
        } else {
            $this.WriteOutputLog($this.StageLog("Prune cancelled by user"))
        }

        $this.WriteLog($this.StageLog("PASS"))
    }

    # Traverses PhotoTranscoder cache to find and delete files older than the specified max age.
    # If $DryRun is $true, don't remove items, just gather statistics.
    [CleanCacheResult] CheckPhotoTranscoderCache([bool] $DryRun) {
        $Cutoff = (Get-Date).AddDays(-$this.Options.CacheAge);
        $AllFiles = 0;
        $OldFiles = 0;
        $FreedBytes = 0;
        Get-ChildItem -Path $this.PlexCache -Recurse -File |
        Where-Object { $_.extension -in '.jpg','.jpeg','.png','.ppm' } |
        ForEach-Object {
            $AllFiles++;
            if ($_.LastWriteTime -lt $Cutoff) {
                $OldFiles++;
                $FreedBytes += $_.Length;
                if (!$DryRun) {
                    Remove-Item $_.FullName;
                }
            }
        };

        return [CleanCacheResult]::new($AllFiles, $OldFiles, $FreedBytes)
    }

    ### Helpers ###

    ### Logging Helpers ###

    [string] Now() { return Get-Date -Format 'yyyy-MM-dd HH.mm.ss' }

    # Write the given text to the console
    [void] Output([string] $Text) {
        if ($this.Options.Scripted) {
            Write-Host "$($this.Now()) $Text"
        } else {
            Write-Host $Text
        }
    }

    # Write the given text as a warning in the console
    [void] OutputWarn([string] $Text) {
        if ($this.Options.Scripted) {
            Write-Warning "$($this.Now()) $Text"
        } else {
            Write-Warning $Text
        }
    }

    # Write the given text to the log file
    [void] WriteLog([string] $Text) {
        Add-Content -Path $this.LogFile -Value "$($this.Now()) -- $($Text)"
    }

    # Write the given text to the log file and console
    [void] WriteOutputLog([string] $Text) {
        $this.WriteLog($Text)
        $this.Output($Text)
    }

    # Write the given text to the log file and as warning text in the console
    [void] WriteOutputLogWarn([string] $Text) {
        $this.WriteLog($Text)
        $this.OutputWarn($Text)
    }

    # Write out the end of the session
    [void] WriteEnd() {
        $this.WriteLog("Session end. $(Get-Date)")
        $this.WriteLog("============================================================")
    }

    # Set the current stage (with the right amount of padding)
    [void] SetStage([string] $Stage) {
        $this.Stage = $Stage + (" " * [math]::Max(0, 8 - $Stage.Length))
    }

    # Prepend the current stage to the given text
    [string] StageLog([string] $text) {
        return "$($this.Stage) - $text"
    }

    ### File Helpers ###

    # Check whether the given directory exists (and is a directory)
    [bool] DirExists([string] $Dir) {
        if ($Dir) {
            return Test-Path $Dir -PathType Container
        }

        return $false
    }

    # Check whether the given file exists (and is a file)
    [bool] FileExists([string] $File) {
        if ($File) {
            return Test-Path $File -PathType Leaf
        }

        return $false
    }

    ### Setup Helpers ###

    # Retrieve Plex's data directory, exiting the script on failure
    [string] GetAppDataDir() {
        $PMSRegistry = $this.GetHKCU()
        $PlexAppData = $PMSRegistry.LocalAppDataPath
        if ($PlexAppData) {
            $PlexAppData = Join-Path -Path $PlexAppData -ChildPath "Plex Media Server"
        }

        if ($this.DirExists($PlexAppData)) {
            return $PlexAppData
        }

        $PlexAppData = "$env:LOCALAPPDATA\Plex Media Server"
        if ($this.DirExists($PlexAppData)) {
            return $PlexAppData
        }

        Write-Host "Could not determine Plex data directory, cannot continue"
        Write-Host "Normally $env:LOCALAPPDATA\Plex Media Server"
        exit
    }

    # Retrieve PMS settings under HKEY_CURRENT_USER, exiting the script on failure
    [PSCustomObject] GetHKCU() {
        try {
            return (Get-ItemProperty -path 'HKCU:\Software\Plex, Inc.\Plex Media Server' -EA Stop)
        } catch {
            Write-Warning "Could not find Plex registry settings (HKCU\Software\Plex, Inc.\Plex Media Server). Are you sure Plex is installed on this machine?"
            exit
        }
    }

    # Set the Plex database directory, returning whether we found the directory
    [bool] GetPlexDBDir([string] $AppData) {
        $DBDir = Join-Path -Path $AppData -ChildPath "Plug-in Support\Databases"
        if ($this.DirExists($DBDir)) {
            $this.PlexDBDir = $DBDir;
            return $true;
        }

        Write-Host "Could not find Databases folder, cannot continue."
        Write-Host "Normally $DBDir"
        return $false
    }

    # Set the path to Plex's PhotoTranscoder cache, returning whether we found the directory.
    [bool] GetPhotoTranscoderDir([string] $AppData) {
        $CacheDir = Join-Path -Path $AppData -ChildPath "Cache\PhotoTranscoder"
        if ($this.DirExists($CacheDir)) {
            $this.PlexCache = $CacheDir
            return $true
        }

        Write-Host "Could not find PhotoTranscoder path, cannot prune."
        Write-Host "Normally $CacheDir"
        return $false
    }

    # Find the path to Plex SQLite.exe, falling back to user input if necessary.
    [bool] GetPlexSQL() {
        $PMSRegistry = $this.GetHKCU()
        $InstallDir = $PMSRegistry.InstallFolder
        if (!$InstallDir) {
            # Install location might also be in HKLM
            $InstallDir = (Get-ItemProperty -path 'HKLM:\SOFTWARE\Plex, Inc.\Plex Media Server' -EA Ignore).InstallFolder
            if (!$InstallDir) {
                # Final registry attempt - WOW6432Node
                $InstallDir = (Get-ItemProperty -path 'HKLM:\SOFTWARE\WOW6432Node\Plex, Inc.\Plex Media Server' -EA Ignore).InstallFolder
            }
        }

        $SQL = if ($InstallDir) { Join-Path -Path $InstallDir -ChildPath "Plex SQLite.exe" } else { $null }
        if ($this.FileExists($SQL)) {
            $this.PlexSQL = $SQL
            return $true
        }

        # Still couldn't find install directory. Try standard PROGRAMFILES variables
        $SQL = "$env:PROGRAMFILES\Plex\Plex Media Server\Plex SQLite.exe"
        if ($this.FileExists($SQL)) {
            $this.PlexSQL = $SQL
            return $true
        }

        if (${env:PROGRAMFILES(X86)}) {
            $SQL = "${env:PROGRAMFILES(X86)}\Plex\Plex Media Server\Plex SQLite.exe"
            if ($this.FileExists($SQL)) {
                Write-Host "Note: 32-bit version of PMS detected on a 64-bit version of Windows. Using the 64-bit release of PMS is recommended."
                $this.PlexSQL = $SQL
                return $true
            }
        }

        Write-Host "Could not determine Plex SQLite location. Please provide it below"
        Write-Host "Normally $env:PROGRAMFILES\Plex\Plex Media Server\Plex SQLite.exe"
        $First = $true
        while (!$this.FileExists($SQL)) {
            if (!$First) {
                Write-Host "ERROR: '$SQL' could not be found"
            }

            $First = $false
            $SQL = Read-Host -Prompt "Path to Plex SQLite.exe (Ctrl+C to cancel): "
        }

        $this.PlexSQL = $SQL
        return $true
    }

    ### Database Helpers ###

    # Report the outcome of a database operation to output/log, tagged with the current stage.
    # Generic across all commands - the stage (set via SetStage) determines the log prefix.
    [void] ExitDBMaintenance([string] $Message, [boolean] $Success) {
        if ($Success) {
            $this.Output($Message)
            $this.WriteLog($this.StageLog("PASS"))
        } else {
            $this.OutputWarn($Message)
            $this.WriteLog($this.StageLog($Message))
            $this.WriteLog($this.StageLog("FAIL"))
        }
    }

    [bool] ExportPlexDB([string] $Source, [string] $Destination) {
        return $this.RunSQLCommand("""$Source"" "".output '$Destination'"" .dump", "Failed to export '$Source' to '$Destination'")
    }

    ### Backup / restore safety net (mirrors DBRepair.sh MakeBackups/RestoreSaved/SetLast) ###

    # Record the most recent undoable operation and the timestamp of its backup.
    [void] SetLast([string] $Name, [string] $Timestamp) {
        $this.LastName = $Name
        $this.LastTimestamp = $Timestamp
    }

    # The six database files that make up a complete backup set (relative to BaseName).
    [string[]] DBFileSuffixes() {
        return @("db", "db-wal", "db-shm", "blobs.db", "blobs.db-wal", "blobs.db-shm")
    }

    # Copy the live database files to persistent '<file>-BACKUP-<timestamp>' files alongside the
    # originals. Returns $false (and cleans up the partial copy) if any copy fails.
    [bool] MakeBackups() {
        $this.Output("Backing up current databases with '-BACKUP-$($this.Timestamp)' timestamp.")
        foreach ($Suffix in $this.DBFileSuffixes()) {
            $File = "$($this.BaseName).$Suffix"
            $Source = Join-Path $this.PlexDBDir -ChildPath $File
            if (!$this.FileExists($Source)) { continue }

            $Backup = Join-Path $this.PlexDBDir -ChildPath "$File-BACKUP-$($this.Timestamp)"
            try {
                Copy-Item -Path $Source -Destination $Backup -Force -EA Stop
                $this.WriteLog($this.StageLog("MakeBackup $File - PASS"))
            } catch {
                $Err = $Error -join "`n"
                $this.OutputWarn("Error while backing up '$File': $Err. Cannot continue.")
                $this.WriteLog($this.StageLog("MakeBackup $File - FAIL"))
                Remove-Item $Backup -Force -EA Ignore
                $Error.Clear()
                return $false
            }
        }

        return $true
    }

    # Move the live database files aside to persistent '<file>-BACKUP-<timestamp>' files. Used by
    # repair before installing rebuilt databases (cheaper than copying for large DBs). Throws on failure.
    [void] BackupLiveByMove() {
        foreach ($Suffix in $this.DBFileSuffixes()) {
            $File = "$($this.BaseName).$Suffix"
            $Live = Join-Path $this.PlexDBDir -ChildPath $File
            if ($this.FileExists($Live)) {
                $this.MoveDatabase($Live, (Join-Path $this.PlexDBDir -ChildPath "$File-BACKUP-$($this.Timestamp)"), "back up $File")
            }
        }
    }

    # Restore the database files from the '-BACKUP-<timestamp>' set, consuming the backup (move).
    # Removes the current live file first so a missing backup (e.g. wal/shm) leaves no stale file.
    [void] RestoreSaved([string] $Timestamp) {
        foreach ($Suffix in $this.DBFileSuffixes()) {
            $File = "$($this.BaseName).$Suffix"
            $Live = Join-Path $this.PlexDBDir -ChildPath $File
            $Backup = Join-Path $this.PlexDBDir -ChildPath "$File-BACKUP-$Timestamp"
            if ($this.FileExists($Live)) { Remove-Item $Live -Force -EA Ignore }
            if ($this.FileExists($Backup)) { Move-Item -Path $Backup -Destination $Live -Force -EA Ignore }
        }
    }

    # Ensure ~Multiplier x (main+blobs DB size) is free on the database volume before a destructive op.
    # Stores SpaceNeeded/SpaceAvailable (MB) for reporting. Returns $true if space is sufficient (or unknown).
    [bool] FreeSpaceAvailable([int] $Multiplier) {
        $Needed = [long]0
        foreach ($db in @($this.MainDB, $this.BlobsDB)) {
            $path = Join-Path $this.PlexDBDir -ChildPath $db
            if ($this.FileExists($path)) { $Needed += (Get-Item $path).Length }
        }
        $Needed = $Needed * $Multiplier
        $this.SpaceNeeded = [math]::Round($Needed / 1MB)

        try {
            $Qualifier = Split-Path -Qualifier $this.PlexDBDir
            $Drive = [System.IO.DriveInfo]::new("$Qualifier\")
            $Available = $Drive.AvailableFreeSpace
        } catch {
            # Can't determine free space (e.g. UNC path) - don't block the operation.
            $Error.Clear()
            $this.SpaceAvailable = -1
            return $true
        }

        $this.SpaceAvailable = [math]::Round($Available / 1MB)
        return $Available -gt $Needed
    }

    # Create (if needed) and return the path to the ephemeral scratch directory, or $null on failure.
    [string] EnsureDBTemp() {
        $DBTemp = Join-Path $this.PlexDBDir -ChildPath "dbtmp"
        if (!$this.DirExists($DBTemp)) {
            $TempDirError = $null
            New-Item -Path $DBTemp -ItemType "directory" -ErrorVariable TempDirError *>$null
            if ($TempDirError) {
                $this.ExitDBMaintenance("Unable to create temporary database directory", $false)
                return $null
            }
        }

        return $DBTemp
    }

    # Return the size of the given file in whole MB (minimum 1 if it exists), 0 if missing.
    [int] GetSizeMB([string] $Path) {
        if (!$this.FileExists($Path)) { return 0 }
        $MB = [math]::Round((Get-Item $Path).Length / 1MB)
        if ($MB -eq 0) { $MB = 1 }
        return $MB
    }

    # Integrity-check a single database. Non-fatal: reports OK/damaged and returns the result.
    [bool] CheckDBIntegrity([string] $DBPath, [string] $DBName) {
        if (!$this.FileExists($DBPath)) {
            $this.OutputWarn("$DBName database not found at $DBPath")
            return $false
        }

        $Result = ""
        $this.Options.CanIgnore = $false
        $Ran = $this.GetSQLCommandResult("""$DBPath"" ""PRAGMA integrity_check(1)""", "Failed to check $DBName DB", [ref]$Result)
        $this.Options.CanIgnore = $true
        if (!$Ran) { return $false }

        if ($Result -eq "ok") {
            $this.Output("Check complete. PMS $DBName database is OK.")
            $this.WriteLog($this.StageLog("Check $DBName - PASS"))
            return $true
        }

        $this.Output("Check complete. PMS $DBName database is damaged: $Result")
        $this.WriteLog($this.StageLog("Check $DBName - FAIL ($Result)"))
        return $false
    }

    # Integrity-check both databases, updating CheckedDB/DBDamaged. Returns $true if all OK.
    # Skips the (potentially slow) check if the databases were already verified healthy this session,
    # unless $Force is set (mirrors DBRepair.sh's CheckedDB flag).
    [bool] CheckDatabases([bool] $Force) {
        if ($this.CheckedDB -and !$this.DBDamaged -and !$Force) {
            return $true
        }

        $this.Output("Checking the PMS databases")
        $MainOK = $this.CheckDBIntegrity((Join-Path $this.PlexDBDir -ChildPath $this.MainDB), "main")
        $BlobsOK = $this.CheckDBIntegrity((Join-Path $this.PlexDBDir -ChildPath $this.BlobsDB), "blobs")
        $this.CheckedDB = $true
        $this.DBDamaged = !($MainOK -and $BlobsOK)
        return !$this.DBDamaged
    }

    # Update the per-operation timestamp (used to name backup files).
    [void] UpdateTimestamp() {
        $this.Timestamp = Get-Date -Format 'yyyy-MM-dd_HH.mm.ss'
    }

    # Run an SQL command.
    # ErrorMessage is the message to output/write to the log on failure
    [bool] RunSQLCommand([string] $Command, [string] $ErrorMessage) {
        return $this.RunSQLCommandCore($Command, $ErrorMessage, $null)
    }

    # Run an SQL command and retrieve the output of said command
    # ErrorMessage is the message to output/write to the log on failure
    [bool] GetSQLCommandResult([string] $Command, [string] $ErrorMessage, [ref] $Output) {
        return $this.RunSQLCommandCore($Command, $ErrorMessage, $Output)
    }

    # Run a 'Plex SQLite' command
    [bool] RunSQLCommandCore([string] $Command, [string] $ErrorMessage, [ref] $Output) {
        $SqlError = $null
        $SqlResult = $null
        $ExitCode = 0
        try {
            Invoke-Expression "& ""$($this.PlexSQL)"" $Command" -ev sqlError -OutVariable sqlResult -EA Stop *>$null
            $ExitCode = $LASTEXITCODE
        } catch {
            $Err = $Error -join "`n"
            $this.ExitDBMaintenance("Failed to run command '$Command': '$Err'", $false)
            $Error.Clear()
            return $false
        }

        if ($SqlError -or $ExitCode) {
            $Err = $SqlError -join "`n"
            if (!$Err) { $Err = "Process exited with error code $ExitCode" }
            $Msg = $ErrorMessage
            if (!$Msg) {
                $Msg = "Plex SQLite operation failed"
            }

            if ($this.Options.IgnoreErrors -and $this.Options.CanIgnore) {
                $this.OutputWarn("Ignoring database errors - ${Msg}: $Err")
            } else {
                $this.ExitDBMaintenance("${Msg}: $Err", $false)
                return $false
            }
        }

        if ($null -ne $Output.Value) {
            $Output.Value = $SqlResult
        }

        return $true
    }

    # Run a 'Plex SQLite' command quietly, capturing combined output. Unlike RunSQLCommand this
    # does no logging or error reporting - it just returns whether the command succeeded, so callers
    # (e.g. FTS checks) can decide what to do. $Output receives stdout on success or the error on failure.
    [bool] TryRunSQL([string] $Command, [ref] $Output) {
        $SqlError = $null
        $SqlResult = $null
        $ExitCode = 0
        try {
            Invoke-Expression "& ""$($this.PlexSQL)"" $Command" -ev sqlError -OutVariable sqlResult -EA Stop *>$null
            $ExitCode = $LASTEXITCODE
        } catch {
            $Output.Value = ($Error -join "`n")
            $Error.Clear()
            return $false
        }

        if ($SqlError -or $ExitCode) {
            $Err = $SqlError -join "`n"
            if (!$Err) { $Err = "Process exited with error code $ExitCode" }
            $Output.Value = $Err
            return $false
        }

        $Output.Value = $SqlResult
        return $true
    }

    # Import an exported .sql file into a new database
    [bool] ImportPlexDB($Source, $Destination) {
        # SQLite's .read can't handle files larger than 2GB on versions <3.45.0 (https://sqlite.org/forum/forumpost/9af57ba66fbb5349),
        # and Plex SQLite is currently on 3.39.4 (as of PMS 1.41.6).
        # If the source is smaller than 2GB we can .read it directly, otherwise do things in a more roundabout way.
        if ($this.FileExists($Source) -and (Get-Item $Source).Length -lt 2GB) {
            return $this.RunSQLCommand("""$Destination"" "".read '$Source'""", "Failed to import Plex database (importing '$Source' into '$Destination')")
        }

        $ImportError = $null
        $ExitCode = 0
        $Err = $null
        try {
            # Use Start-Process, since PowerShell doesn't have '<', and alternatives ("Get-Content X | SQLite.exe OutDB") are subpar at best when dealing with large files like these database exports.
            $process = Start-Process $this.PlexSQL -ArgumentList @("""$Destination""") -RedirectStandardInput $Source -NoNewWindow -Wait -PassThru -EA Stop -ErrorVariable ImportError
            $ExitCode = $process.ExitCode
        } catch {
            $Err = $Error -join "`n"
            $Error.Clear()
        }

        if ($ImportError) {
            $Err = $ImportError -join "`n"
        } elseif ($ExitCode) {
            if ($this.Options.IgnoreErrors) {
                $this.OutputWarn("Ignoring errors found during import")
            } else {
                $Err = "Process exited with error code $ExitCode (constraint error?)"
            }
        }

        if ($Err) {
            $this.ExitDBMaintenance("Failed to import Plex database (importing '$Source' into '$Destination'): $Err", $false)
            return $false
        }

        return $true
    }

    [bool] IntegrityCheck([string] $Database, [string] $DbName) {
        $this.Options.CanIgnore = $false
        $VerifyResult = ""
        $result = $this.GetSQLCommandResult("""$Database"" ""PRAGMA integrity_check(1)""", "Failed to verify $dbName DB", [ref]$VerifyResult)
        if ($result) {
            $this.Output("$DbName DB verification check is: $VerifyResult")
            if ($VerifyResult -ne "ok") {
                $this.ExitDBMaintenance("$DbName DB verification failed: $VerifyResult", $false)
                $result = $false
            }
        }

        $this.Options.CanIgnore = $true
        return $result
    }

    # Clear out the temp database directory. If $Confirm is $true, asks the user before doing so.
    [void] CleanDBTemp([bool] $Confirm) {
        if ($Confirm -and !$this.GetYesNo("Ok to remove temporary databases/workfiles for this session")) {
            $this.Output("Retaining all temporary work files.")
            $this.WriteLog("Exit    - Retain temp files.")
            return
        }

        $DBTemp = Join-Path $this.PlexDBDir -ChildPath "dbtmp"
        if ($this.DirExists($DBTemp)) {
            try {
                Remove-Item $DBTemp -Recurse -Force -EA Stop
                $this.Output("Deleted all temporary work files.")
                $this.WriteLog("Exit    - Deleted temp files.")
            } catch {
                $Err = $Error -join "`n"
                $this.OutputWarn("Failed to remove temporary directory: $Err")
                $this.WriteLog("Exit    - Failed to remove temporary files: $Err")
                $Error.Clear()
            }
        }
    }

    ### Miscellaneous Helpers ###

    # Return whether PMS is running
    [bool] PMSRunning() {
        return $null -ne $this.GetPMS()
    }

    # Retrieve the PMS process, if running
    [System.Diagnostics.Process] GetPMS() {
        return Get-Process -EA Ignore -Name "Plex Media Server"
    }

    # Ask the user a yes or no question, continuing to prompt them until
    # their input starts with either a 'Y' or 'N'
    [bool] GetYesNo([string] $Prompt) {
        $Response = (Read-Host "$Prompt [Y/N]? ").ToLower()
        $Ch = $Response.Substring(0, [Math]::Min($Response.Length, 1))
        while (($Ch -ne "y") -and ($Ch -ne "n")) {
            Write-Host "Invalid input, please enter [Y]es or [N]o"
            $Response = (Read-Host "$Prompt [Y/N]? ").ToLower()
            $Ch = $Response.Substring(0, [Math]::Min($Response.Length, 1))
        }

        return $Ch -eq "y"
    }
}

# Contains miscellaneous options/state over the course of a session.
class DBRepairOptions {
    [bool] $Scripted # Whether we're running in scripted or interactive mode
    [bool] $ShowMenu # Whether to show the menu after each command executes
    [bool] $IgnoreErrors # Whether to honor or ignore constraint errors on import
    [bool] $CanIgnore # Some errors can't be ignored (e.g. integrity_check)
    [int32] $CacheAge # The date cutoff for pruning PhotoTranscoder cached images

    DBRepairOptions() {
        $this.CacheAge = 30
        $this.ShowMenu = $true
        $this.Scripted = $false
        $this.IgnoreErrors = $false
        $this.CanIgnore = $true
    }
}

# Contains relevant data about a PhotoTranscoder `prune` attempt
class CleanCacheResult {
    [int32] $TotalFiles    # Total number of PhotoTranscoder files
    [int32] $PrunableFiles # Total number of files that are older than the cutoff
    [string] $SpaceSavings # Friendly string of (potential) space savings

    CleanCacheResult([int32] $TotalFiles, [int32] $PrunableFiles, [int32] $PrunableBytes) {
        $this.TotalFiles = $TotalFiles
        $this.PrunableFiles = $PrunableFiles
        $this.SpaceSavings = "$($PrunableBytes) bytes"

        if ($PrunableBytes -gt 1GB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1GB, 2)) GiB";
        } elseif ($PrunableBytes -gt 1MB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1MB, 2)) MiB";
        } elseif ($PrunableBytes -gt 1KB) {
            $this.SpaceSavings = "$([math]::round($PrunableBytes / 1KB, 2)) KiB";
        }
    }
}

# Ensure the console can handle utf-8, as the export process pipes utf-8 data from the console to our temporary sql file.
$InputEncodingSave = [console]::InputEncoding
$OutputEncodingSave = [console]::OutputEncoding
[console]::InputEncoding = [console]::OutputEncoding = New-Object System.Text.UTF8Encoding

[void]([DBRepair]::new($args, $DBRepairVersion))

[console]::OutputEncoding = $OutputEncodingSave
[console]::InputEncoding = $InputEncodingSave
