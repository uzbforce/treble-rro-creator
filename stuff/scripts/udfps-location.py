import re
import subprocess


# Function to run shell commands via adb
def adb_shell(cmd, quiet=False):
    if not quiet:
        print(f"Running adb shell command: {cmd}")
    result = subprocess.run(['adb', 'shell', cmd], capture_output=True, text=True)
    output = result.stdout.replace('\r', '').strip()
    if result.returncode != 0:
        error = result.stderr.replace('\r', '').strip()
        if error:
            print(f"Command failed ({result.returncode}): {error}")
    elif output and not quiet:
        print(f"Command output: {output}")
    return output


# Function to read a property from the device
def get_prop(name):
    return adb_shell(f'getprop {name}', quiet=True)


# Function to read file content from Android system via adb shell
def read_file(path):
    print(f"Reading file: {path}")
    return adb_shell(f'cat {path}')


# Xiaomi stores the FOD area as a rectangle, not as a center point:
#   persist.vendor.sys.fp.fod.location.X_Y      = left,top
#   persist.vendor.sys.fp.fod.size.width_height = width,height
# The framework resource wants the center and radius instead.
def xiaomi_fod_rect(display_width, display_height):
    candidates = (
        ('persist.vendor.sys.fp.fod.location.X_Y',
         'persist.vendor.sys.fp.fod.size.width_height'),
        # Android 8 used the same names without "vendor".
        ('persist.sys.fp.fod.location.X_Y',
         'persist.sys.fp.fod.size.width_height'),
    )

    for location_prop, size_prop in candidates:
        location = get_prop(location_prop)
        size = get_prop(size_prop)
        if not location or not size:
            continue

        location_values = [int(value) for value in re.findall(r'\d+', location)]
        size_values = [int(value) for value in re.findall(r'\d+', size)]
        if len(location_values) < 2 or len(size_values) < 2:
            print(f"Ignoring malformed FOD properties: {location_prop}={location}, "
                  f"{size_prop}={size}")
            continue

        left, top = location_values[:2]
        width, height = size_values[:2]
        if width <= 0 or height <= 0:
            print(f"Ignoring zero-sized FOD area: {size_prop}={size}")
            continue

        print(f"Found Xiaomi FOD rectangle: left={left}, top={top}, "
              f"width={width}, height={height}")

        if width > display_width or height > display_height \
                or left < 0 or top < 0 \
                or left + width > display_width or top + height > display_height:
            print("Warning: that rectangle does not fit inside the reported display; "
                  "check the values before using them.")

        return {
            "mX": left + width // 2,
            "mY": top + height // 2,
            "mW": min(width, height) // 2,
            "source": f"{location_prop} + {size_prop}",
        }

    return None


# Function to get screen properties via adb shell dumpsys commands
def get_display_properties():
    print("Fetching display properties (size and density) via adb shell...")

    # Get real display size
    display_size_output = adb_shell("wm size")
    display_metrics_output = adb_shell("wm density")

    # Parse the physical size. `wm size` also prints an optional override,
    # which is not the panel resolution the kernel values are based on.
    display_size = None
    for line in display_size_output.splitlines():
        if "Physical size" in line:
            display_size = line.split()[-1].split('x')
            break
    if display_size is None:
        display_size = display_size_output.split()[-1].split('x')

    # wm density prints both the physical and an optional override. The
    # physical density is the one the panel uses, and the one the kernel's
    # millimetre-to-pixel conversion must match.
    display_metrics = None
    for line in display_metrics_output.splitlines():
        if "Physical density" in line:
            display_metrics = int(line.split()[-1])
            break
    if display_metrics is None:
        display_metrics = int(display_metrics_output.split()[-1])

    display_width = int(display_size[0])
    display_height = int(display_size[1])

    print(f"Display width: {display_width}px")
    print(f"Display height: {display_height}px")
    print(f"Display DPI: {display_metrics}")

    return display_width, display_height, display_metrics


# Function to calculate the required properties
def dynamic_udfps_props():
    display_width, display_height, dpi = get_display_properties()

    print("Looking for a Xiaomi FOD rectangle in the device properties...")
    xiaomi_props = xiaomi_fod_rect(display_width, display_height)
    if xiaomi_props:
        return xiaomi_props

    print("Fetching fingerprint position data from the kernel sysfs file...")
    # Some kernels expose the position as millimetres from the bottom edge.
    position_data = read_file("/sys/class/fingerprint/fingerprint/position")

    if not position_data:
        print("Fingerprint position data not found.")
        return None

    print(f"Fingerprint position data: {position_data}")

    # Parse fingerprint position data
    fod_position_array = list(map(float, position_data.split(",")))

    bottom_mm = fod_position_array[0]
    area_size_mm = fod_position_array[5]
    height_mm = fod_position_array[2]

    print(f"Bottom MM: {bottom_mm}mm")
    print(f"Area size MM: {area_size_mm}mm")
    print(f"Height MM: {height_mm}mm")

    # Convert to inches
    bottom_inch = bottom_mm * 0.0393700787
    area_size_inch = area_size_mm * 0.0393700787

    # Convert to pixels
    bottom_px = int(bottom_inch * dpi)
    area_size_px = int(area_size_inch * dpi)
    mid_dist_px = int(area_size_inch * dpi / 2.0)

    print(f"Bottom in pixels: {bottom_px}px")
    print(f"Area size in pixels: {area_size_px}px")

    # Calculate the center position
    m_w = area_size_px / 2
    m_x = display_width / 2
    m_y = display_height - bottom_px - mid_dist_px

    return {
        "mX": int(m_x),
        "mY": int(m_y),
        "mW": int(m_w),
        "source": "/sys/class/fingerprint/fingerprint/position",
    }


# Print the config.env lines this tool expects
def print_config_env(udfps_props):
    if not udfps_props:
        print("Unable to calculate the fingerprint sensor dimensions.")
        return

    print(f"\nSource: {udfps_props['source']}")
    print("Add these lines to config.env (then rebuild):\n")
    print("HAS_UDFPS=true")
    print(f"UDFPS_X={udfps_props['mX']}")
    print(f"UDFPS_Y={udfps_props['mY']}")
    print(f"UDFPS_RADIUS={udfps_props['mW']}")
    print("\nAdjust UDFPS_RADIUS only if the unlock area does not match the sensor.")


# Main function
if __name__ == "__main__":
    udfps_props = dynamic_udfps_props()
    print_config_env(udfps_props)
