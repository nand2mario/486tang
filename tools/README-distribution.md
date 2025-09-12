
This explains how to create standalone executables for the ao486 toolbox that users can run without installing Python.

### Quick Build

```bash
# Install build dependencies
pip install -r requirements-build.txt

# Build executable
python build.py
```

The executable will be created in `dist/486tang-toolbox` (or `dist/486tamg-toolbox.exe` on Windows).
