import os
import subprocess

# Function to run shell commands via adb
def adb_shell(cmd):
    print(f"Running adb shell command: {cmd}")
    result = subprocess.run(['adb', 'shell', cmd], capture_output=True, text=True)
    print(f"Command output: {result.stdout.strip()}")
    return result.stdout.strip()

# Function to read file content from Android system via adb shell
def read_file(path):
    print(f"Reading file: {path}")
    return adb_shell(f'cat {path}')

# Function to get screen properties via adb shell dumpsys commands
def get_display_properties():
    print("Fetching display properties (size and density) via adb shell...")
    
    # Get real display size
    display_size_output = adb_shell("wm size")
    display_metrics_output = adb_shell("wm density")
    
    # Parse real size
    display_size = display_size_output.split()[-1].split('x')
    display_metrics = int(display_metrics_output.split()[-1])  # DPI (dots per inch)
    
    display_width = int(display_size[0])
    display_height = int(display_size[1])

    print(f"Display width: {display_width}px")
    print(f"Display height: {display_height}px")
    print(f"Display DPI: {display_metrics}")
    
    return display_width, display_height, display_metrics

# Function to calculate the required properties
def dynamic_udfps_props():
    print("Fetching fingerprint position data from device...")
    # Read the fingerprint position file
    position_data = read_file("/sys/class/fingerprint/fingerprint/position")
    
    if position_data:
        print(f"Fingerprint position data: {position_data}")
        
        # Get display properties
        display_width, display_height, dpi = get_display_properties()
        
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
        
        udfps_props = {
            "mX": int(m_x),
            "mY": int(m_y),
            "mW": int(m_w)
        }

        print(f"Calculated mX: {udfps_props['mX']}px")
        print(f"Calculated mY: {udfps_props['mY']}px")
        print(f"Calculated mW: {udfps_props['mW']}px")
        
        return udfps_props
    else:
        print("Fingerprint position data not found.")
        return None

# Function to print the desired XML with calculated values
def print_dimen_xml(udfps_props):
    if udfps_props:
        print(f"""
<dimen name="physical_fingerprint_sensor_center_screen_location_x">{udfps_props['mX']}px</dimen>
<dimen name="physical_fingerprint_sensor_center_screen_location_y">{udfps_props['mY']}px</dimen>
        """)
    else:
        print("Unable to calculate the fingerprint sensor dimensions.")

# Main function
if __name__ == "__main__":
    udfps_props = dynamic_udfps_props()
    print_dimen_xml(udfps_props)
