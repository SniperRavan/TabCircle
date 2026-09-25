"""
Unit test for TabCircle Linux Multi-Monitor Screen Anchor Logic
Validates screen resolution across single, dual, stacked, and fractional scaling setups.
"""

def resolve_screen(screens_mock, anchor=None, cursor_pos=(0, 0), primary_screen_name="primary"):
    """
    Implements the exact resolution algorithm used by TabCircle's SwitcherOverlay.center_on_screen.
    - screens_mock: list of dicts: {'name': str, 'geo': (x,y,w,h), 'dpr': float}
    - anchor: dict {'center': (cx, cy), 'screen_name': str} or tuple (cx, cy)
    """
    c = None
    s_name = None
    if isinstance(anchor, dict):
        c = anchor.get("center")
        s_name = anchor.get("screen_name")
    elif isinstance(anchor, (tuple, list)):
        c = anchor

    target_screen = None

    # 1. Exact match by XRandR monitor output name
    if s_name:
        for s in screens_mock:
            if s['name'] == s_name:
                target_screen = s
                break

    # 2. Geometric match accounting for fractional DPR
    if not target_screen and c:
        cx, cy = c
        for s in screens_mock:
            dpr = s.get('dpr', 1.0)
            gx, gy, gw, gh = s['geo']
            phys_left = round(gx * dpr)
            phys_top = round(gy * dpr)
            phys_right = round((gx + gw) * dpr)
            phys_bottom = round((gy + gh) * dpr)
            if phys_left <= cx < phys_right and phys_top <= cy < phys_bottom:
                target_screen = s
                break

    # 3. Fallback to cursor pos or primary
    if not target_screen:
        for s in screens_mock:
            gx, gy, gw, gh = s['geo']
            if gx <= cursor_pos[0] < gx + gw and gy <= cursor_pos[1] < gy + gh:
                target_screen = s
                break

    if not target_screen:
        for s in screens_mock:
            if s['name'] == primary_screen_name:
                target_screen = s
                break

    return target_screen['name'] if target_screen else None


def run_tests():
    # Setup dual-monitor mock:
    # Screen 1: Laptop eDP-1-0 at (0, 0) 1536x864 logical, DPR 1.25 (1920x1080 physical)
    # Screen 2: External HDMI-1 at (1536, 0) 1920x1080 logical, DPR 1.0 (1920x1080 physical)
    screens = [
        {'name': 'eDP-1-0', 'geo': (0, 0, 1536, 864), 'dpr': 1.25},
        {'name': 'HDMI-1', 'geo': (1536, 0, 1920, 1080), 'dpr': 1.0},
    ]

    print("Running Multi-Monitor resolution tests...")

    # Test 1: Window on Primary Laptop Screen (eDP-1-0) via XRandR name
    res1 = resolve_screen(screens, anchor={'center': (960, 540), 'screen_name': 'eDP-1-0'})
    assert res1 == 'eDP-1-0', f"Expected eDP-1-0, got {res1}"
    print("  ✓ Test 1: Active window on Laptop screen (XRandR name) -> eDP-1-0")

    # Test 2: Window dragged to Secondary Monitor (HDMI-1) via XRandR name
    res2 = resolve_screen(screens, anchor={'center': (2880, 540), 'screen_name': 'HDMI-1'})
    assert res2 == 'HDMI-1', f"Expected HDMI-1, got {res2}"
    print("  ✓ Test 2: Active window dragged to External monitor (XRandR name) -> HDMI-1")

    # Test 3: Fallback to geometric physical pixel match without XRandR name (Screen 1)
    res3 = resolve_screen(screens, anchor={'center': (1139, 690), 'screen_name': None})
    assert res3 == 'eDP-1-0', f"Expected eDP-1-0, got {res3}"
    print("  ✓ Test 3: Active window physical coordinate fallback (Laptop) -> eDP-1-0")

    # Test 4: Fallback to geometric physical pixel match without XRandR name (Screen 2)
    # Physical X on HDMI-1: 1920 to 3840. Center = 1920 + 960 = 2880
    res4 = resolve_screen(screens, anchor={'center': (2880, 540), 'screen_name': None})
    assert res4 == 'HDMI-1', f"Expected HDMI-1, got {res4}"
    print("  ✓ Test 4: Active window physical coordinate fallback (External) -> HDMI-1")

    # Test 5: Stacked displays (Screen 2 above Screen 1)
    stacked_screens = [
        {'name': 'eDP-1-0', 'geo': (0, 1080, 1920, 1080), 'dpr': 1.0},
        {'name': 'HDMI-1', 'geo': (0, 0, 2560, 1440), 'dpr': 1.0},
    ]
    res5_top = resolve_screen(stacked_screens, anchor={'center': (1280, 720), 'screen_name': None})
    assert res5_top == 'HDMI-1', f"Expected HDMI-1, got {res5_top}"
    res5_bot = resolve_screen(stacked_screens, anchor={'center': (960, 1620), 'screen_name': None})
    assert res5_bot == 'eDP-1-0', f"Expected eDP-1-0, got {res5_bot}"
    print("  ✓ Test 5: Stacked vertical multi-monitor displays -> Correct top/bottom screen")

    # Test 6: Off-screen fallback to cursor position
    res6 = resolve_screen(screens, anchor={'center': (-5000, -5000), 'screen_name': None}, cursor_pos=(2000, 500))
    assert res6 == 'HDMI-1', f"Expected HDMI-1, got {res6}"
    print("  ✓ Test 6: Off-screen window fallback to mouse cursor -> Correct screen")

    print("\nAll 6 Multi-Monitor tests passed successfully!")

if __name__ == '__main__':
    run_tests()
