# Ubuntu-Autoinstall

## Quickstart

0. **Initial setup: Install required packages**
   - Run: `task setup`

1. **Download the official Ubuntu ISO**
   - Run: `task iso:download`
   - The ISO will be placed in `DATA/ISO/official/`.

2. **Extract the ISO**
   - Run: `task iso:extract`

3. **Apply patches and autoinstall config**
   - Edit `nocloud/user-data` and `nocloud/meta-data` as needed.
   - Run: `task iso:patch`

4. **Remaster the ISO**
   - Run: `task iso:remaster`
   - The new ISO will be in `DATA/ISO/remastered/`.