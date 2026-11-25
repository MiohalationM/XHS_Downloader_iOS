Offline Live Photo regression fixtures (synthetic/anonymized metadata with
real HEIC + H.264 MP4 Live Photo sample pair for lossless pairing tests).

livephoto-original.heic: 2160 x 2880 Display P3 HEIC still with Apple content
identifier and sample processing telemetry string for PhotoImportMetadata tests.
livephoto-motion.mp4: associated H.264 motion stream for LivePhotoPairer tests.
livephoto-note.json: offline mobile __INITIAL_STATE__ payload fixture.

These samples test preservation and native Live Photo recognition. Display P3
alone is not evidence of HDR; this sample must not be called an HDR gain-map test.
