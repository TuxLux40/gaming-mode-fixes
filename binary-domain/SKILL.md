---
title: Binary Domain Linux Proton Fixes
description: Comprehensive guide to running Binary Domain on Linux with Proton
version: 1.0.0
platforms: 
  - Linux
  - Steam Proton
tools:
  - protontricks
  - Wine
  - DXVK

prerequisites:
  - Steam installed
  - Proton GE or Proton Experimental
  - AMD/RADV GPU

problems_solved:
  - Graphics device initialization
  - Audio middleware compatibility
  - Controller input mapping

fixes:
  1. Audio Chain:
     - Use FAudio instead of native XAudio2
     - Set `WINEDLLOVERRIDES=faudio=n,b`
     - Configure `PULSE_LATENCY_MSEC=60`

  2. Graphics GUID:
     - Manually select GPU in game configuration
     - Write persistent GUID to `UserCFG.txt`
     - Ensure adapter detection works

  3. Launch Options:
     ```bash
     DISABLE_GAMESCOPE_WSI=1 PULSE_LATENCY_MSEC=60 WINEDLLOVERRIDES=faudio=n,b %command%
     ```

pitfalls:
  - Do NOT delete `UserCFG.txt`
  - Rerun fix if GPU changes
  - Test after each Proton update

files_created:
  - `/home/oliver/Projects/gaming-mode-fixes/binary-domain/UserCFG.txt`
  - `/home/oliver/Projects/gaming-mode-fixes/binary-domain/fix-binary-domain-guid.sh`
  - `/home/oliver/Projects/gaming-mode-fixes/binary-domain/NOTES.md`

verification_steps:
  1. Launch goes to main menu without errors
  2. Audio plays correctly
  3. Game detects graphics adapter
  4. No Wine/DXVK error messages in log
---