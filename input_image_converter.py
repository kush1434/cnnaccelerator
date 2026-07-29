from PIL import Image


def image_to_mem_a(image_path, output_path="mem_a.hex"):
    # Mem A holds 64 pixels, so resize to 8 × 8
    image = Image.open(image_path).convert("L")
    image = image.resize((8, 8))

    pixels = list(image.getdata())

    with open(output_path, "w") as file:
        for pixel in pixels:
            # Convert unsigned grayscale 0–255 to signed -128–127
            signed_pixel = pixel - 128

            # Convert signed value to 8-bit two's-complement hex
            encoded_pixel = signed_pixel & 0xFF

            file.write(f"{encoded_pixel:02X}\n")

    print(f"Stored {len(pixels)} pixels in {output_path}")


image_to_mem_a("image.png")
