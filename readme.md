# FLAC encoder (and maybe decoder)
A flac encoder written entirely in zig for learning purposes \
\
Zig version 0.14.0
## Done
- Encoding
  - Format
    - All sampling rate (by flac standard) (only 44.1kHz tested yet)
    - Full byte sample depth (by flac standatd) (only 16bits tested yet)
  - Metadata
    - Streaminfo
      - Also MD5
    - Vendor Signature
  - Subframe
    - Subframe type selection
    - Constant
    - Verbatim
    - Fixed Prediction
      - Escaped partition not tested
- Decoding
  - PCM s16le WAV file (naively)
## Progressing
- Subframe
  - Subframe type selection
  - Linear Prediction
## Queued
- Stereo mode selection
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
