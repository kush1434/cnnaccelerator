from pathlib import Path

import numpy as np
from PIL import Image


INPUT_FILE = Path("output_maps.txt")

NUM_FILTERS = 4
HEIGHT = 6
WIDTH = 6
DISPLAY_SCALE = 100


def normalize_for_display(feature_map: np.ndarray) -> np.ndarray:
    minimum = feature_map.min()
    maximum = feature_map.max()

    if minimum == maximum:
        return np.zeros((HEIGHT, WIDTH), dtype=np.uint8)

    normalized = (
        (feature_map.astype(np.float64) - minimum)
        * 255.0
        / (maximum - minimum)
    )

    return normalized.astype(np.uint8)


def main() -> None:
    values = np.loadtxt(INPUT_FILE, dtype=np.int64).reshape(-1)

    expected = NUM_FILTERS * HEIGHT * WIDTH

    if values.size != expected:
        raise ValueError(
            f"Expected {expected} values, but found {values.size}"
        )

    # The testbench writes 36 values for each filter consecutively.
    maps = values.reshape(NUM_FILTERS, HEIGHT, WIDTH)

    for filter_number, feature_map in enumerate(maps):
        print(f"\nFilter {filter_number}:")
        print(feature_map)

        display_map = normalize_for_display(feature_map)

        image = Image.fromarray(display_map, mode="L")

        image = image.resize(
            (WIDTH * DISPLAY_SCALE, HEIGHT * DISPLAY_SCALE),
            Image.Resampling.NEAREST,
        )

        output_file = Path(
            f"feature_map_filter_{filter_number}.png"
        )

        image.save(output_file)
        print(f"Saved {output_file}")


if __name__ == "__main__":
    main()
