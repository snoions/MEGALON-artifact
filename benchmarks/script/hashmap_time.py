import os
import re
import sys
import statistics

default_pattern = r"(?:Thread Average time: )(\d+(\.\d+)?)(?:.*)"

def parse_and_analyze(file_path, pattern):
    data_points = []

    try:
        with open(file_path, 'r') as f:
            for line in f:
                match = re.search(pattern, line)
                if match:
                    value = float(match.groups()[0])
                    data_points.append(value)

        # Calculate and Print Statistics
        if not data_points:
            raise ValueError("No matching lines found")
        avg = statistics.mean(data_points)
        std_dev = statistics.stdev(data_points) if len(data_points) > 1 else 0.0
        return (avg, std_dev)

    except FileNotFoundError:
        print(f"Error: The file '{file_path}' was not found.")
    except Exception as e:
        # This catches the ValueError if float conversion fails
        print(f"An error occurred: {e}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
       file = sys.argv[1]
       pattern = re.compile(sys.argv[2]) if len(sys.argv) > 2 else default_pattern
       avg, std_dev = parse_and_analyze(file, pattern)
       print(f"{avg:.4f},{std_dev:.4f}")
    else:
       print(f"Usage: {os.path.basename(__file__)} <logfile> [pattern]")
