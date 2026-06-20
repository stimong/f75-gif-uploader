# AULA GIF Uploader

Tiny macOS uploader for AULA keyboard LCD GIF/image screens.

It keeps the flow intentionally small:

1. Double-click the app.
2. Choose the keyboard model.
3. Drop or choose an image/GIF.
4. Adjust width, height, or frame limit if needed.
5. Press **Send to Keyboard**.
6. Watch the progress bar finish.

The app bundles the independently reverse-engineered `F75Probe` helper from
`RoseWaveStudio/Aula-F75-Max-OSX` and calls it for the actual HID upload. This
project is not affiliated with Aula, Epomaker, or the official Windows driver.

## Safety Checks

- Accepts GIF, PNG, JPG, and JPEG files.
- Checks the first frame dimensions and source frame count.
- Uses model presets:
  - AULA F108Pro: 240 x 135, recommended max 32 frames.
  - AULA F75 Max: 128 x 128, recommended max 120 frames.
- Allows manual width, height, and frame limit overrides.
- Trims animated GIF upload to the selected frame limit instead of rejecting it.
- Uses the shared wired screen upload path exposed by the keyboard HID endpoints.

## Requirements

- macOS 14 or newer
- Apple Silicon Mac recommended
- Supported AULA keyboard in wired USB mode
- Input Monitoring permission if macOS requests it

## Build

```sh
make all
open build/AulaGifUploader.app
```

## Notes

Screen upload requires the wired USB device path `0C45:800A` and the HID
screen endpoints `0xff13` and `0xff68`. F108Pro has been verified with a
240 x 135 GIF payload; F75 Max uses 128 x 128.
