# Third-party components

Hej's Pets source is MIT licensed. The Windows package dynamically bundles these unmodified components; their own terms apply:

- Qt / PySide6 / Shiboken6 (6.8.3), LGPL-3.0 / GPL-3.0 / commercial: https://doc.qt.io/qtforpython-6/licenses.html
- Pillow (11.1.0), HPND: https://github.com/python-pillow/Pillow
- pillow-heif (0.22.0), BSD-3-Clause; bundled libheif and codec libraries retain their respective licenses: https://github.com/bigcat88/pillow_heif
- NumPy (2.0.2), BSD-3-Clause: https://github.com/numpy/numpy
- OpenCV (4.11.0.86), Apache-2.0; Haar cascades retain their supplied license notices: https://github.com/opencv/opencv
- Python, PSF: https://docs.python.org/3/license.html
- PyInstaller bootloader, GPL with the distribution exception: https://pyinstaller.org/en/stable/license.html

Installed package metadata and available license files are included under `_internal`. Qt libraries are separate DLLs, not statically linked; replacement with compatible versions is permitted under their licenses. Source and build instructions for this application are available in this repository. Corresponding upstream sources are linked above. No photo datasets or downloaded face models are distributed; the local Haar cascade XML files ship with OpenCV.
