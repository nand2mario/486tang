#!/usr/bin/env python3
"""
Build script for creating standalone ao486 toolbox executables
"""

import subprocess
import sys
import os
import shutil
from pathlib import Path

def build_executable():
    """Build standalone executable using PyInstaller."""
    
    # Check if PyInstaller is installed
    try:
        import PyInstaller
    except ImportError:
        print("Installing PyInstaller...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "pyinstaller"])
    
    # Clean previous builds
    build_dirs = ["build", "dist", "__pycache__"]
    for dir_name in build_dirs:
        if os.path.exists(dir_name):
            shutil.rmtree(dir_name)
            print(f"Cleaned {dir_name}/")
    
    # PyInstaller command
    cmd = [
        "pyinstaller",
        "--onefile",                    # Single executable
        "--windowed",                   # No console window (GUI only)
        "--name", "486tang-toolbox",    # Executable name
        "--add-data", "mksdcard.py:.",  # Include mksdcard.py
        "--hidden-import", "tkinter",   # Ensure tkinter is included
        "--hidden-import", "serial",    # Ensure pyserial is included
        "--hidden-import", "pygame",    # Ensure pygame is included
        "486tang.py"
    ]
    
    print("Building standalone executable...")
    print(f"Command: {' '.join(cmd)}")
    
    try:
        subprocess.check_call(cmd)
        print("\n✅ Build successful!")
        print(f"Executable location: {os.path.abspath('dist/486tang-toolbox')}")
        print("\nTo test the executable:")
        print("  ./dist/486tang-toolbox")
        
        # Show file size
        exe_path = "dist/486tang-toolbox"
        if os.name == 'nt':  # Windows
            exe_path += ".exe"
        
        if os.path.exists(exe_path):
            size_mb = os.path.getsize(exe_path) / (1024 * 1024)
            print(f"Executable size: {size_mb:.1f} MB")
            
    except subprocess.CalledProcessError as e:
        print(f"❌ Build failed: {e}")
        return False
    
    return True

def create_spec_file():
    """Create a custom .spec file for more control."""
    spec_content = '''
# -*- mode: python ; coding: utf-8 -*-

block_cipher = None

a = Analysis(
    ['486tang.py'],
    pathex=[],
    binaries=[],
    datas=[('mksdcard.py', '.')],
    hiddenimports=['tkinter', 'serial', 'pygame'],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=block_cipher,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

exe = EXE(
    pyz,
    a.scripts,
    a.binaries,
    a.zipfiles,
    a.datas,
    [],
    name='486tang-toolbox',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    runtime_tmpdir=None,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
)

# macOS app bundle (optional)
# app = BUNDLE(exe,
#              name='486tang-toolbox.app',
#              icon=None,
#              bundle_identifier='com.486tang.toolbox')
'''
    
    with open('486tang-toolbox.spec', 'w') as f:
        f.write(spec_content.strip())
    
    print("Created 486tang-toolbox.spec file")
    print("You can now run: pyinstaller 486tang-toolbox.spec")

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description='Build 486tang toolbox executable')
    parser.add_argument('--spec-only', action='store_true', help='Only create .spec file')
    args = parser.parse_args()
    
    if args.spec_only:
        create_spec_file()
    else:
        build_executable()