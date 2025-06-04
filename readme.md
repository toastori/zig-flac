# FLAC encoder (and maybe decoder)
A flac encoder written entirely in zig for learning purposes \
\
Zig version 0.14.0
## Done
- Encoding
  - Format
    - All sampling rates (by flac standard) (44.1/96 kHz tested)
    - Full byte sample depth (by flac standard) (16/24 bits tested)
  - Metadata
    - Streaminfo
      - Write min/max frame size
      - Calculate MD5
    - Vendor Signature
  - Stereo mode selection
  - Subframe
    - Subframe type selection
    - Constant
    - Verbatim
    - Fixed Prediction
      - Escaped partition not tested
- Decoding
  - PCM WAV file (little endian)
  - PCM WAV extensible file (little endian)
## Progressing
- Subframe
  - Subframe type selection
  - Linear Prediction
## Queued
- Proper cmd args
- Metadata
  - Vorbis Comments
  - Padding
- Flac Decoder
- Lib (and C Lib)
## Future
- 4, 12, 20 bits audio
- Assembly SIMD optimization
- Metadata
  - Cuesheet
  - Picture
  - Seek Table
- Dynamic frame size
