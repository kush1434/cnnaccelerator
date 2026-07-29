from PIL import Image

 #you have to install pillow using the command pip install pillow
def image_to_matrix(filename):
    # Open the image and convert it to 8-bit grayscale
    image = Image.open(filename).convert("L")

    width, height = image.size
    pixels = list(image.getdata())

    # Convert the flat pixel list into a 2D matrix
    matrix = [
        pixels[row * width:(row + 1) * width]
        for row in range(height)
    ]

    return matrix


matrix = image_to_matrix("image.png")  # Also works with .jpg and .jpeg

for row in matrix:
    print(row)