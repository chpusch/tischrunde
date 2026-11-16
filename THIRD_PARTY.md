# Fremdcode und Quellen

Tischrunde enthält **keinen fremden Quellcode**. Alle Algorithmen sind selbst implementiert. Die folgenden Quellen dienten als Grundlage für Formeln und Kennwerte:

| Quelle | Wofür | Lizenz/Status |
|---|---|---|
| Robert Bristow-Johnson, *Cookbook formulae for audio EQ biquad filter coefficients* (W3C Audio EQ Cookbook) | Formeln für Hoch- und Tiefpass (`Biquad.swift`) | Formelsammlung, frei verwendbar; kein Code übernommen |
| ITU-R BS.1770-4, *Algorithms to measure audio programme loudness and true-peak audio level* | K-Bewertung (Koeffizienten), Blockbildung und Gating (`Loudness.swift`) | Internationaler Standard; nur Kennwerte übernommen |
| EBU R 128 / EBU Tech 3341 | Ziel- und Referenzwerte der Lautheit | Empfehlung; nur Kennwerte übernommen |
| Cooley/Tukey (1965), iterative Radix-2-FFT | `FFT.swift` | Lehrbuch-Algorithmus |

## Externe Programme (nicht enthalten)

- **ffmpeg** mit **LAME** (LGPL/GPL): Wird nur für den optionalen MP3-Export als separates Programm aufgerufen, wenn es auf dem Mac installiert ist (`brew install ffmpeg`). Tischrunde linkt ffmpeg nicht und liefert es nicht mit. Die MIT-Lizenz von Tischrunde ist davon nicht berührt.

## Apple-Frameworks

AVFoundation, Accelerate, SwiftUI und AppKit sind Bestandteil von macOS und werden über die öffentlichen Schnittstellen genutzt.
