#!/usr/bin/env python3

import sys
import os
import glob
import platform
import argparse
import serial  # pyserial

CMD_PS2_SCANCODE = 0x0C
CMD_PS2_MOUSE    = 0x0E

# PS/2 Set 2 scancodes, modeled after verilator/scancode.h.
# Values can be either:
# - [make...] list           -> break is auto-generated
# - (make_list, break_list)  -> explicit break sequence (for special keys)
# Reference: https://www.win.tue.nl/~aeb/linux/kbd/scancodes-10.html
KEYMAP = {
    # Letters
    'a': [0x1C], 'b': [0x32], 'c': [0x21], 'd': [0x23], 'e': [0x24],
    'f': [0x2B], 'g': [0x34], 'h': [0x33], 'i': [0x43], 'j': [0x3B],
    'k': [0x42], 'l': [0x4B], 'm': [0x3A], 'n': [0x31], 'o': [0x44],
    'p': [0x4D], 'q': [0x15], 'r': [0x2D], 's': [0x1B], 't': [0x2C],
    'u': [0x3C], 'v': [0x2A], 'w': [0x1D], 'x': [0x22], 'y': [0x35],
    'z': [0x1A],
    # Digits (top row) and shifted symbols map to same make
    '1': [0x16], '2': [0x1E], '3': [0x26], '4': [0x25], '5': [0x2E],
    '6': [0x36], '7': [0x3D], '8': [0x3E], '9': [0x46], '0': [0x45],
    # Punctuation / symbols
    'backquote': [0x0E],
    'minus': [0x4E], 'underscore': [0x4E],
    'equals': [0x55], 'plus': [0x55],
    'leftbracket': [0x54], 'rightbracket': [0x5B],
    'backslash': [0x5D],
    'semicolon': [0x4C], 'colon': [0x4C],
    'quote': [0x52], 'doublequote': [0x52],
    'comma': [0x41], 'less': [0x41],
    'period': [0x49], 'greater': [0x49],
    'slash': [0x4A], 'question': [0x4A],
    # Control and lock keys
    'enter': [0x5A], 'esc': [0x76], 'backspace': [0x66], 'tab': [0x0D], 'space': [0x29],
    'capslock': [0x58], 'numlock': [0x77], 'scrolllock': [0x7E],
    'leftshift': [0x12], 'rightshift': [0x59],
    'leftctrl': [0x14], 'rightctrl': [0xE0, 0x14],
    'leftalt': [0x11], 'rightalt': [0xE0, 0x11],
    # Function keys
    'f1': [0x05], 'f2': [0x06], 'f3': [0x04], 'f4': [0x0C], 'f5': [0x03], 'f6': [0x0B],
    'f7': [0x83], 'f8': [0x0A], 'f9': [0x01], 'f10': [0x09], 'f11': [0x78], 'f12': [0x07],
    # Special multi-byte
    'printscreen': ([0xE0, 0x12, 0xE0, 0x7C], [0xE0, 0xF0, 0x7C, 0xE0, 0xF0, 0x12]),
    'pause': ([0xE1, 0x14, 0x77, 0xE1, 0xF0, 0x14, 0xE0, 0x77], []),
    # Navigation / edit cluster (extended)
    'insert': [0xE0, 0x70], 'home': [0xE0, 0x6C], 'pageup': [0xE0, 0x7D],
    'delete': [0xE0, 0x71], 'end': [0xE0, 0x69], 'pagedown': [0xE0, 0x7A],
    # Arrow keys (extended)
    'up': [0xE0, 0x75], 'down': [0xE0, 0x72], 'left': [0xE0, 0x6B], 'right': [0xE0, 0x74],
    # Numpad
    'kp_divide': [0xE0, 0x4A], 'kp_multiply': [0x7C], 'kp_minus': [0x7B],
    'kp_7': [0x6C], 'kp_8': [0x75], 'kp_9': [0x7D], 'kp_plus': [0x79],
    'kp_4': [0x6B], 'kp_5': [0x73], 'kp_6': [0x74],
    'kp_1': [0x69], 'kp_2': [0x72], 'kp_3': [0x7A],
    'kp_0': [0x70], 'kp_period': [0x71],
    'kp_enter': [0xE0, 0x5A], 'kp_equals': [0xE0, 0x5A],
}


def frame(payload: bytes) -> bytes:
    length = len(payload)
    if length > 0x07FF:
        raise ValueError('frame too long')
    return bytes([0xAA, (length >> 8) & 0xFF, length & 0xFF]) + payload


def build_scancode_frame(scancodes: bytes) -> bytes:
    payload = bytes([CMD_PS2_SCANCODE]) + scancodes
    return frame(payload)

def build_mouse_frame(mouse_bytes: bytes) -> bytes:
    payload = bytes([CMD_PS2_MOUSE]) + mouse_bytes
    return frame(payload)

# ---------------------- PS/2 mouse helpers ----------------------

def ps2_mouse_packet(dx: int, dy: int, buttons: int) -> bytes:
    """
    Build a 3-byte PS/2 mouse packet.
    buttons: bit0=L, bit1=R, bit2=M
    dx, dy: relative movement; positive dy from pygame means down, PS/2 expects inverted Y.
    """
    def clamp8(v):
        return max(-128, min(127, v))
    x_ovf = 0
    y_ovf = 0
    if dx < -128 or dx > 127:
        x_ovf = 1
    if dy < -128 or dy > 127:
        y_ovf = 1
    dx = clamp8(dx)
    dy = clamp8(-dy)  # invert Y for PS/2 packet
    b0 = 0x08
    if buttons & 0x1: b0 |= 0x01  # L
    if buttons & 0x2: b0 |= 0x02  # R
    if buttons & 0x4: b0 |= 0x04  # M
    if dx < 0: b0 |= 0x10
    if dy < 0: b0 |= 0x20
    if x_ovf: b0 |= 0x40
    if y_ovf: b0 |= 0x80
    return bytes([b0, dx & 0xFF, dy & 0xFF])


def _get_make_break(keyname):
    v = KEYMAP[keyname]
    if isinstance(v, tuple):
        return list(v[0]), list(v[1])
    return list(v), None


def _derive_break_from_make(make_bytes):
    out = []
    i = 0
    while i < len(make_bytes):
        b = make_bytes[i]
        if b == 0xE0:
            out.append(0xE0)
            i += 1
            if i < len(make_bytes):
                out.extend([0xF0, make_bytes[i]])
        elif b == 0xE1:
            # No generic break for E1-prefixed sequences (Pause). Skip.
            return []
        else:
            out.extend([0xF0, b])
        i += 1
    return out


def expand_keys_to_scancodes(names, pressed=True):
    out = []
    for name in names:
        key = name.lower()
        if key not in KEYMAP:
            raise KeyError(f'Unknown key: {name}')
        make, brk = _get_make_break(key)
        if pressed:
            out.extend(make)
        else:
            if brk is not None:
                out.extend(brk)
            else:
                out.extend(_derive_break_from_make(make))
    return bytes(out)


def parse_hex_bytes(args):
    out = []
    for a in args:
        out.append(int(a, 16) & 0xFF)
    return bytes(out)


def send(port, baud, payload: bytes):
    with serial.Serial(port, baudrate=baud, timeout=1) as ser:
        ser.write(payload)
        ser.flush()


# ---------------------- Interactive support (pygame) ----------------------

def run_interactive(port, baud):
    import pygame

    ser = serial.Serial(port, baudrate=baud, timeout=0)
    pygame.init()
    try:
        win = pygame.display.set_mode((480, 160))
    except Exception:
        # Fallback to headless if video init fails
        pygame.display.init()
        win = pygame.display.set_mode((1, 1))
    pygame.display.set_caption('ao486 I/O (click to capture mouse; GUI+ESC to release)')
    font = pygame.font.Font(None, 24)
    clock = pygame.time.Clock()

    def send_sc(sc_bytes: bytes):
        ser.write(build_scancode_frame(sc_bytes))
    def send_mouse(mouse_bytes: bytes):
        if not mouse_bytes:
            return
        ser.write(build_mouse_frame(mouse_bytes))

    # --------- PS/2 mouse device emulation (host<->device) ---------
    # Respond to controller->mouse bytes arriving as response type 0x06 frames.
    ps2_id = 0x00           # basic mouse by default (becomes 0x03 after 200-100-80)
    rate_seq = []           # track magic sequence for IntelliMouse
    expect_value_for = None # 'F3' or 'E8'
    streaming_enabled = False

    def mouse_reply_byte(b: int):
        # Wrap a single device->host byte as a type 0x0E command back to FPGA
        ser.write(build_mouse_frame(bytes([b & 0xFF])))

    def on_host_to_mouse_byte(b: int):
        nonlocal ps2_id, rate_seq, expect_value_for, streaming_enabled
        # Handle second byte of prior F3/E8 first
        if expect_value_for == 'F3':
            # Host sends sample rate value; acknowledge
            mouse_reply_byte(0xFA)
            # Track magic sequence 200, 100, 80
            rate_seq.append(b & 0xFF)
            if len(rate_seq) > 3:
                rate_seq = rate_seq[-3:]
            if rate_seq == [200, 100, 80]:
                ps2_id = 0x03
            expect_value_for = None
            return
        if expect_value_for == 'E8':
            # Host sends resolution value; acknowledge
            mouse_reply_byte(0xFA)
            expect_value_for = None
            return

        # Interpret as a command byte
        cmd = b & 0xFF
        if cmd == 0xFF:            # Reset
            mouse_reply_byte(0xFA) # ACK
            mouse_reply_byte(0xAA) # BAT OK
            mouse_reply_byte(0x00) # device ID after reset per many implementations
            streaming_enabled = False
            rate_seq.clear()
            ps2_id = 0x00
        elif cmd == 0xF2:          # Get ID
            mouse_reply_byte(0xFA)
            mouse_reply_byte(ps2_id)
        elif cmd == 0xF3:          # Set sample rate (expects 1 data byte)
            mouse_reply_byte(0xFA)
            expect_value_for = 'F3'
        elif cmd == 0xE8:          # Set resolution (expects 1 data byte)
            mouse_reply_byte(0xFA)
            expect_value_for = 'E8'
        elif cmd in (0xE6, 0xE7, 0xF0, 0xF5, 0xF6, 0xEA):
            # Common commands we just ACK
            #  E6/E7 scaling, F0 set remote/wrap (ignored), F5 disable, F6 defaults, EA set stream (not strictly used here)
            mouse_reply_byte(0xFA)
            if cmd == 0xF5:
                streaming_enabled = False
            elif cmd in (0xEA, 0xF4):
                streaming_enabled = True
        elif cmd == 0xF4:          # Enable streaming
            mouse_reply_byte(0xFA)
            streaming_enabled = True
        elif cmd == 0xE9:          # Status
            mouse_reply_byte(0xFA)
            # 3 status bytes: we can send zeros for simplicity
            mouse_reply_byte(0x00)
            mouse_reply_byte(0x00)
            mouse_reply_byte(0x00)
        else:
            # Unknown -> RESEND (FE) is a conservative choice
            mouse_reply_byte(0xFE)

    # UART frame reader: handle type 0x06 (host->mouse) and 0x07 (debug)
    rx_buf = bytearray()
    rx_state = 'SEEK'
    rx_len = 0
    rx_payload = bytearray()

    last_text = ''
    mouse_text = ''
    captured = False
    buttons = 0  # bit0 L, bit1 R, bit2 M

    def set_capture(on: bool):
        nonlocal captured
        captured = on
        try:
            pygame.event.set_grab(on)
        except Exception:
            pass
        try:
            pygame.mouse.set_visible(not on)
        except Exception:
            pass
    running = True
    while running:
        for ev in pygame.event.get():
            if ev.type == pygame.QUIT:
                running = False
            elif ev.type == pygame.MOUSEBUTTONDOWN:
                if not captured:
                    set_capture(True)
                    mouse_text = 'Mouse captured'
                else:
                    b = ev.button
                    if b == 1: buttons |= 0x1
                    elif b == 3: buttons |= 0x2
                    elif b == 2: buttons |= 0x4
                    pkt = ps2_mouse_packet(0, 0, buttons)
                    send_mouse(pkt)
                    mouse_text = f'Btn down {b}: {pkt.hex()}'
            elif ev.type == pygame.MOUSEBUTTONUP and captured:
                b = ev.button
                if b == 1: buttons &= ~0x1
                elif b == 3: buttons &= ~0x2
                elif b == 2: buttons &= ~0x4
                pkt = ps2_mouse_packet(0, 0, buttons)
                send_mouse(pkt)
                mouse_text = f'Btn up {b}: {pkt.hex()}'
            elif ev.type == pygame.MOUSEMOTION and captured:
                dx, dy = ev.rel
                pkt = ps2_mouse_packet(dx, dy, buttons)
                send_mouse(pkt)
                mouse_text = f'Move {dx},{dy}: {pkt.hex()}'
            elif ev.type in (pygame.KEYDOWN, pygame.KEYUP):
                name = pygame_key_to_name(ev.key)
                # Release capture on GUI+ESC (Cmd-ESC/Win-ESC)
                if ev.type == pygame.KEYDOWN and ev.key == getattr(pygame, 'K_ESCAPE') and (ev.mod & getattr(pygame, 'KMOD_GUI')):
                    set_capture(False)
                    mouse_text = 'Mouse released (GUI+ESC)'
                    continue
                if name is None:
                    continue
                pressed = (ev.type == pygame.KEYDOWN)
                sc = expand_keys_to_scancodes([name], pressed=pressed)
                send_sc(sc)
                last_text = f"{name} {'down' if pressed else 'up'}: {sc.hex()}"

        # Poll UART for incoming frames
        while True:
            data = ser.read(256)
            if not data:
                break
            # print(f"rx: {data.hex()}")
            rx_buf.extend(data)
            # parse frames
            while True:
                if rx_state == 'SEEK':
                    # Look for 0xAA
                    idx = rx_buf.find(b'\xAA')
                    if idx < 0:
                        rx_buf.clear()
                        break
                    if idx > 0:
                        del rx_buf[:idx]
                    if len(rx_buf) < 4:
                        break
                    rx_len = (rx_buf[1] << 8) | rx_buf[2]
                    # payload should have rx_len bytes
                    if len(rx_buf) < 3 + rx_len:
                        break
                    rx_payload = bytearray(rx_buf[3:3+rx_len])
                    del rx_buf[:3+rx_len]
                    rx_state = 'HAVE'
                if rx_state == 'HAVE':
                    if not rx_payload:
                        rx_state = 'SEEK'
                        continue
                    rtype = rx_payload[0]
                    body = rx_payload[1:]
                    if rtype == 0x06:
                        # host->mouse byte stream; may be multiple bytes if we aggregate later
                        print(f"host->mouse: {body.hex()}")
                        for bb in body:
                            on_host_to_mouse_byte(bb)
                    elif rtype == 0x07:
                        # debug text: print as ASCII
                        try:
                            sys.stdout.write(body.decode('latin1'))
                            sys.stdout.flush()
                        except Exception:
                            pass
                    # Done
                    rx_state = 'SEEK'

        # Simple status draw
        win.fill((0, 0, 0))
        txt1 = font.render(last_text, True, (200, 200, 200))
        win.blit(txt1, (10, 10))
        txt2 = font.render(("[Captured] " if captured else "[Click to capture] ") + mouse_text, True, (150, 180, 220))
        win.blit(txt2, (10, 40))
        pygame.display.flip()
        clock.tick(120)

    ser.close()


def pygame_key_to_name(k):
    import pygame
    # Letters
    if pygame.K_a <= k <= pygame.K_z:
        return chr(k - pygame.K_a + ord('a'))
    # Digits
    if pygame.K_0 <= k <= pygame.K_9:
        return chr(k)
    # Common controls
    mapping = {
        pygame.K_RETURN: 'enter',
        pygame.K_ESCAPE: 'esc',
        pygame.K_BACKSPACE: 'backspace',
        pygame.K_TAB: 'tab',
        pygame.K_SPACE: 'space',
        pygame.K_LSHIFT: 'leftshift',
        pygame.K_RSHIFT: 'rightshift',
        pygame.K_LCTRL: 'leftctrl',
        pygame.K_RCTRL: 'rightctrl',
        pygame.K_LALT: 'leftalt',
        pygame.K_RALT: 'rightalt',
        pygame.K_CAPSLOCK: 'capslock',
        # SDL2/Pygame2 naming difference support (both included for safety)
        getattr(pygame, 'K_NUMLOCKCLEAR', pygame.K_CLEAR): 'numlock',
        getattr(pygame, 'K_SCROLLOCK', pygame.K_SCROLLLOCK) if hasattr(pygame, 'K_SCROLLOCK') else pygame.K_SCROLLLOCK: 'scrolllock',
        pygame.K_UP: 'up',
        pygame.K_DOWN: 'down',
        pygame.K_LEFT: 'left',
        pygame.K_RIGHT: 'right',
        pygame.K_F1: 'f1', pygame.K_F2: 'f2', pygame.K_F3: 'f3', pygame.K_F4: 'f4',
        pygame.K_F5: 'f5', pygame.K_F6: 'f6', pygame.K_F7: 'f7', pygame.K_F8: 'f8',
        pygame.K_F9: 'f9', pygame.K_F10: 'f10', pygame.K_F11: 'f11', pygame.K_F12: 'f12',
        # Punctuation
        pygame.K_BACKQUOTE: 'backquote',
        pygame.K_MINUS: 'minus',
        pygame.K_EQUALS: 'equals',
        pygame.K_LEFTBRACKET: 'leftbracket',
        pygame.K_RIGHTBRACKET: 'rightbracket',
        pygame.K_BACKSLASH: 'backslash',
        pygame.K_SEMICOLON: 'semicolon',
        pygame.K_QUOTE: 'quote',
        pygame.K_COMMA: 'comma',
        pygame.K_PERIOD: 'period',
        pygame.K_SLASH: 'slash',
        # Nav cluster
        pygame.K_INSERT: 'insert',
        pygame.K_HOME: 'home',
        pygame.K_PAGEUP: 'pageup',
        pygame.K_DELETE: 'delete',
        pygame.K_END: 'end',
        pygame.K_PAGEDOWN: 'pagedown',
        # PrintScreen / Pause
        getattr(pygame, 'K_PRINTSCREEN', pygame.K_SYSREQ): 'printscreen',
        pygame.K_PAUSE: 'pause',
        # Numpad
        pygame.K_KP_DIVIDE: 'kp_divide',
        pygame.K_KP_MULTIPLY: 'kp_multiply',
        pygame.K_KP_MINUS: 'kp_minus',
        pygame.K_KP_PLUS: 'kp_plus',
        pygame.K_KP_ENTER: 'kp_enter',
        pygame.K_KP_EQUALS: 'kp_equals',
        pygame.K_KP_PERIOD: 'kp_period',
        pygame.K_KP0: 'kp_0', pygame.K_KP1: 'kp_1', pygame.K_KP2: 'kp_2', pygame.K_KP3: 'kp_3',
        pygame.K_KP4: 'kp_4', pygame.K_KP5: 'kp_5', pygame.K_KP6: 'kp_6', pygame.K_KP7: 'kp_7',
        pygame.K_KP8: 'kp_8', pygame.K_KP9: 'kp_9',
    }
    return mapping.get(k)




from typing import Optional


def auto_detect_port() -> Optional[str]:
    """On macOS, choose the alphabetically last /dev/tty.usbserial* device."""
    if platform.system() != 'Darwin':
        return None
    cands = sorted(glob.glob('/dev/tty.usbserial*'))
    return cands[-1] if cands else None


def run_gui():
    """Run the tabbed GUI interface."""
    import tkinter as tk
    from tkinter import ttk, filedialog, messagebox, scrolledtext
    import threading
    import queue
    import subprocess
    import sys
    import os
    
    # Import mksdcard functionality
    sys.path.append(os.path.dirname(__file__))
    from mksdcard import create_sdcard_image
    
    root = tk.Tk()
    root.title("486Tang Toolbox")
    root.geometry("900x650")
    
    # Create notebook for tabs
    notebook = ttk.Notebook(root)
    notebook.pack(fill='both', expand=True, padx=10, pady=10)
    
    # Tab 1: Keyboard/Mouse Emulation
    kb_frame = ttk.Frame(notebook)
    notebook.add(kb_frame, text="Keyboard/Mouse")
    
    # Tab 2: SD Card Creator
    sd_frame = ttk.Frame(notebook)
    notebook.add(sd_frame, text="SD Card Creator")
    
    # === Keyboard/Mouse Tab ===
    ttk.Label(kb_frame, text="486Tang Keyboard/Mouse Emulator", font=("Arial", 14, "bold")).pack(pady=10)
    
    # Serial port selection
    port_frame = ttk.Frame(kb_frame)
    port_frame.pack(fill='x', padx=20, pady=5)
    ttk.Label(port_frame, text="Serial Port:").pack(side='left')
    port_var = tk.StringVar()
    port_entry = ttk.Entry(port_frame, textvariable=port_var, width=30)
    port_entry.pack(side='left', padx=(10, 5))
    
    def auto_detect():
        port = auto_detect_port()
        if port:
            port_var.set(port)
        else:
            messagebox.showwarning("No Port", "No serial port found")
    
    ttk.Button(port_frame, text="Auto Detect", command=auto_detect).pack(side='left', padx=5)
    
    # Baud rate
    baud_frame = ttk.Frame(kb_frame)
    baud_frame.pack(fill='x', padx=20, pady=5)
    ttk.Label(baud_frame, text="Baud Rate:").pack(side='left')
    baud_var = tk.StringVar(value="115200")
    ttk.Combobox(baud_frame, textvariable=baud_var, values=["9600", "115200", "2000000"], width=15).pack(side='left', padx=10)
    
    # Interactive mode button
    interactive_frame = ttk.Frame(kb_frame)
    interactive_frame.pack(pady=20)
    
    interactive_process = None
    
    def start_interactive():
        nonlocal interactive_process
        if interactive_process and interactive_process.poll() is None:
            messagebox.showwarning("Already Running", "Interactive mode is already running")
            return
            
        port = port_var.get().strip()
        baud = baud_var.get().strip()
        
        if not port:
            messagebox.showerror("Error", "Please enter a serial port")
            return
            
        try:
            # Determine if running as script or executable
            if getattr(sys, 'frozen', False):
                # Running as PyInstaller executable
                executable = sys.executable
                args = [executable, '-p', port, '-b', baud, 'interactive']
            else:
                # Running as Python script
                executable = sys.executable
                args = [executable, __file__, '-p', port, '-b', baud, 'interactive']
            
            # Start interactive mode as subprocess
            interactive_process = subprocess.Popen(args, cwd=os.path.dirname(sys.executable))
            messagebox.showinfo("Started", f"Starting interactive mode on {port} at {baud} baud...")
        except Exception as e:
            messagebox.showerror("Error", f"Failed to start interactive mode: {e}")
    
    def stop_interactive():
        nonlocal interactive_process
        if interactive_process and interactive_process.poll() is None:
            interactive_process.terminate()
            messagebox.showinfo("Stopped", "Interactive mode stopped")
        else:
            messagebox.showinfo("Not Running", "Interactive mode is not running")
    
    ttk.Button(interactive_frame, text="Start Interactive Mode", command=start_interactive).pack(side='left', padx=5)
    ttk.Button(interactive_frame, text="Stop Interactive Mode", command=stop_interactive).pack(side='left', padx=5)
    
    # Status display
    status_text = scrolledtext.ScrolledText(kb_frame, height=8, width=80)
    status_text.pack(fill='both', expand=True, padx=20, pady=10)
    status_text.insert('1.0', "486Tang Keyboard/Mouse Emulator\n\n")
    status_text.insert('end', "Click 'Auto Detect' to find serial port, then 'Start Interactive Mode' to begin.\n")
    status_text.insert('end', "In interactive mode:\n")
    status_text.insert('end', "- Click window to capture mouse\n")
    status_text.insert('end', "- Cmd/Win + ESC to release mouse\n")
    status_text.insert('end', "- All keyboard input will be forwarded to 486Tang\n")
    
    # === SD Card Creator Tab ===
    ttk.Label(sd_frame, text="SD Card Image Creator", font=("Arial", 14, "bold")).pack(pady=10)
    
    # File selection frame
    files_frame = ttk.Frame(sd_frame)
    files_frame.pack(fill='x', padx=20, pady=10)
    
    # BIOS file
    bios_frame = ttk.Frame(files_frame)
    bios_frame.pack(fill='x', pady=5)
    ttk.Label(bios_frame, text="BIOS File:", width=18).pack(side='left')
    bios_var = tk.StringVar(value="boot0.rom")
    ttk.Entry(bios_frame, textvariable=bios_var, width=45).pack(side='left', padx=5)
    def select_bios():
        file = filedialog.askopenfilename(title="Select BIOS file", filetypes=[("All files", "*.*")])
        if file:
            bios_var.set(file)
    ttk.Button(bios_frame, text="Browse...", command=select_bios, width=15).pack(side='left', padx=5)
    
    # VGA BIOS file
    vga_frame = ttk.Frame(files_frame)
    vga_frame.pack(fill='x', pady=5)
    ttk.Label(vga_frame, text="VGA BIOS File:", width=18).pack(side='left')
    vga_var = tk.StringVar(value="boot1.rom")
    ttk.Entry(vga_frame, textvariable=vga_var, width=45).pack(side='left', padx=5)
    def select_vga():
        file = filedialog.askopenfilename(title="Select VGA BIOS file", filetypes=[("All files", "*.*")])
        if file:
            vga_var.set(file)
    ttk.Button(vga_frame, text="Browse...", command=select_vga, width=15).pack(side='left', padx=5)
    
    # HDD file
    hdd_frame = ttk.Frame(files_frame)
    hdd_frame.pack(fill='x', pady=5)
    ttk.Label(hdd_frame, text="Hard Disk Image:", width=18).pack(side='left')
    hdd_var = tk.StringVar(value="dos6_256mb.vhd")
    ttk.Entry(hdd_frame, textvariable=hdd_var, width=45).pack(side='left', padx=5)
    def select_hdd():
        file = filedialog.askopenfilename(title="Select hard disk image", filetypes=[("Disk images", "*.img *.vhd"), ("All files", "*.*")])
        if file:
            hdd_var.set(file)
    ttk.Button(hdd_frame, text="Browse...", command=select_hdd, width=15).pack(side='left', padx=5)
    
    # Create empty VHD button
    empty_vhd_frame = ttk.Frame(files_frame)
    empty_vhd_frame.pack(fill='x', pady=5)
    ttk.Label(empty_vhd_frame, text="", width=18).pack(side='left')  # Empty label for alignment
    ttk.Label(empty_vhd_frame, text="Size (MB):").pack(side='left', padx=(0, 5))
    vhd_size_var = tk.StringVar(value="256")
    ttk.Entry(empty_vhd_frame, textvariable=vhd_size_var, width=8).pack(side='left', padx=5)
    
    def create_empty_vhd():
        try:
            size_mb = int(vhd_size_var.get())
            if size_mb <= 0:
                messagebox.showerror("Error", "Size must be greater than 0")
                return
        except ValueError:
            messagebox.showerror("Error", "Invalid size value")
            return
        
        # Ask for save location
        file = filedialog.asksaveasfilename(
            title="Save empty VHD as", 
            defaultextension=".vhd",
            filetypes=[("VHD files", "*.vhd"), ("All files", "*.*")],
            initialfile=f"empty_{size_mb}mb.vhd"
        )
        
        if not file:
            return
            
        # Check if file already exists and confirm overwrite
        if os.path.exists(file):
            result = messagebox.askyesno(
                "File Exists", 
                f"The file '{os.path.basename(file)}' already exists.\n\nDo you want to overwrite it?",
                icon="warning"
            )
            if not result:
                return
            
        # Create empty VHD in background thread
        def create_thread():
            try:
                progress_var.set(f"Creating empty {size_mb}MB VHD file...")
                root.update()
                
                # Create file filled with zeros
                size_bytes = size_mb * 1024 * 1024
                chunk_size = 1024 * 1024  # Write 1MB at a time
                
                with open(file, 'wb') as f:
                    remaining = size_bytes
                    while remaining > 0:
                        write_size = min(chunk_size, remaining)
                        f.write(b'\x00' * write_size)
                        remaining -= write_size
                        
                        # Update progress
                        percent = ((size_bytes - remaining) * 100) // size_bytes
                        progress_var.set(f"Creating empty {size_mb}MB VHD file... {percent}%")
                        root.update()
                
                # Set the created file as the HDD selection
                hdd_var.set(file)
                progress_var.set(f"Empty {size_mb}MB VHD created successfully!")
                messagebox.showinfo("Success", f"Empty VHD created: {file}")
                
            except Exception as e:
                progress_var.set(f"Error creating VHD: {e}")
                messagebox.showerror("Error", f"Failed to create VHD: {e}")
        
        threading.Thread(target=create_thread, daemon=True).start()
    
    ttk.Button(empty_vhd_frame, text="Create Empty VHD", command=create_empty_vhd, width=15).pack(side='left', padx=5)
    
    # Output file
    output_frame = ttk.Frame(files_frame)
    output_frame.pack(fill='x', pady=5)
    ttk.Label(output_frame, text="Output SD Image:", width=18).pack(side='left')
    output_var = tk.StringVar(value="sdcard.img")
    ttk.Entry(output_frame, textvariable=output_var, width=45).pack(side='left', padx=5)
    def select_output():
        file = filedialog.asksaveasfilename(title="Save SD card image as", 
                                         defaultextension=".img",
                                         filetypes=[("Disk images", "*.img"), ("All files", "*.*")])
        if file:
            output_var.set(file)
    ttk.Button(output_frame, text="Browse...", command=select_output, width=15).pack(side='left', padx=5)
    
    # Memory size
    mem_frame = ttk.Frame(files_frame)
    mem_frame.pack(fill='x', pady=10)
    ttk.Label(mem_frame, text="Total Memory (MB):", width=20).pack(side='left')
    mem_var = tk.StringVar(value="8")
    ttk.Spinbox(mem_frame, from_=1, to=64, textvariable=mem_var, width=10).pack(side='left', padx=5)
    
    # Create button and progress
    create_frame = ttk.Frame(sd_frame)
    create_frame.pack(fill='x', padx=20, pady=10)
    
    progress_var = tk.StringVar(value="Ready to create SD card image")
    ttk.Label(create_frame, textvariable=progress_var).pack()
    
    def create_image():
        bios = bios_var.get().strip()
        vga = vga_var.get().strip()
        hdd = hdd_var.get().strip()
        output = output_var.get().strip()
        
        if not all([bios, vga, hdd, output]):
            messagebox.showerror("Error", "Please select all required files")
            return
            
        try:
            mem_mb = int(mem_var.get())
        except ValueError:
            messagebox.showerror("Error", "Invalid memory size")
            return
            
        # Run creation in thread to avoid blocking GUI
        def create_thread():
            try:
                progress_var.set("Creating SD card image...")
                root.update()
                success = create_sdcard_image(bios, vga, hdd, output, mem_mb)
                if success:
                    progress_var.set("SD card image created successfully!")
                    messagebox.showinfo("Success", f"SD card image created: {output}")
                else:
                    progress_var.set("Failed to create SD card image")
                    messagebox.showerror("Error", "Failed to create SD card image")
            except Exception as e:
                progress_var.set(f"Error: {e}")
                messagebox.showerror("Error", f"Error creating SD card image: {e}")
        
        threading.Thread(target=create_thread, daemon=True).start()
    
    ttk.Button(create_frame, text="Create SD Card Image", command=create_image).pack(pady=10)
    
    # Log area for SD card creation
    log_text = scrolledtext.ScrolledText(sd_frame, height=12, width=80)
    log_text.pack(fill='both', expand=True, padx=20, pady=10)
    log_text.insert('1.0', "SD Card Image Creator\n\n")
    log_text.insert('end', "Select the required files:\n")
    log_text.insert('end', "1. BIOS file (placed at offset 0), e.g. boot0.rom\n")
    log_text.insert('end', "2. VGA BIOS file (placed at offset 64KB), e.g. boot1.rom\n") 
    log_text.insert('end', "3. Hard disk image (placed at offset 128KB), e.g. dos.vhd\n")
    log_text.insert('end', "4. Choose output filename for SD card image, e.g. sdcard.img\n\n")
    log_text.insert('end', "The tool will combine all files into a single SD card image\n")
    log_text.insert('end', "with proper offsets and configuration data.\n")
    
    # Auto-detect serial port on startup
    auto_detect()
    
    root.mainloop()


def main():
    # New CLI with options, but keep backward compatibility with legacy positional form.
    parser = argparse.ArgumentParser(description='ao486 keyboard/mouse UART bridge')
    parser.add_argument('-p', '--port', help='Serial port. On macOS, auto-selects last /dev/tty.usbserial* if omitted')
    parser.add_argument('-b', '--baud', type=int, help='Baud rate (default 115200)')
    parser.add_argument('--gui', action='store_true', help='Launch GUI interface')
    parser.add_argument('rest', nargs='*', help='Back-compat: [port baud] mode [args ...] or mode [args ...]')
    args = parser.parse_args()

    # Check for GUI mode first (or if no arguments provided, default to GUI)
    if args.gui or (not args.rest and not args.port and not args.baud):
        run_gui()
        return

    port = args.port
    baud = args.baud
    rest = args.rest

    MODES = {'hex', 'keys', 'key', 'interactive'}

    # Interpret positional args in a backward-compatible way.
    mode = None
    tail = []

    if rest:
        if rest[0] in MODES:
            # New style: mode first
            mode = rest[0]
            tail = rest[1:]
        elif len(rest) >= 3 and rest[2] in MODES:
            # Legacy: <port> <baud> <mode> [...]
            port = port or rest[0]
            if baud is None:
                try:
                    baud = int(rest[1])
                except ValueError:
                    parser.error('Invalid baud in legacy form')
            mode = rest[2]
            tail = rest[3:]
        else:
            parser.error('Unrecognized arguments. Use: [--port P] [--baud B] <mode> [args...] or legacy: <port> <baud> <mode> [args...]')
    else:
        parser.error('Missing mode. Use: [--port P] [--baud B] <mode> [args...] or --gui for GUI interface')

    # Defaults / auto-detect
    if port is None:
        port = auto_detect_port()
        if port:
            print(f'Using serial port: {port}', file=sys.stderr)
        else:
            parser.error('No --port provided and auto-detect failed (looking for /dev/tty.usbserial* on macOS)')

    if baud is None:
        baud = 115200

    # Execute mode
    if mode == 'hex':
        sc = parse_hex_bytes(tail)
        data = build_scancode_frame(sc)
        send(port, baud, data)
    elif mode == 'keys':
        sc = expand_keys_to_scancodes(tail, pressed=True)
        data = build_scancode_frame(sc)
        send(port, baud, data)
    elif mode == 'key':
        if len(tail) != 2:
            parser.error('key mode: need <name> <down|up>')
        name, action = tail[0], tail[1].lower()
        if action not in ('down', 'up'):
            parser.error('action must be down|up')
        sc = expand_keys_to_scancodes([name], pressed=(action == 'down'))
        data = build_scancode_frame(sc)
        send(port, baud, data)
    elif mode == 'interactive':
        run_interactive(port, baud)
    else:
        parser.error('Unknown mode')


if __name__ == '__main__':
    main()
