import qrcode
from PIL import Image, ImageDraw, ImageFont

def create_wifi_qr_with_text(font_path="arial.ttf", initial_font_size=24):
    # User prompt
    ssid = input("Please enter Wi-Fi name (SSID): ")
    password = input("Please enter Wi-Fi password: ")
    
    # Prepare the text for under the QR code
    text = f"SSID: {ssid}\nPassword: {password}"

    # Create the Wi-Fi access point in the correct formatting
    wifi_access_point = f"WIFI:T:WPA;S:{ssid};P:{password};;"

    # Creating the QR code
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(wifi_access_point)
    qr.make(fit=True)

    # Create an image from the QR code
    img = qr.make_image(fill_color="black", back_color="white").convert("RGB")
    original_width, original_height = img.size

    # Adjust font size to fit text width
    font_size = initial_font_size
    font = ImageFont.truetype(font_path, font_size)
    draw = ImageDraw.Draw(img)
    max_text_width = max(draw.textlength(line, font=font) for line in text.split('\n'))
    
    # Decrease the font size until the text fits the width of the QR code
    while max_text_width > original_width and font_size > 1:
        font_size -= 1  # Decrease font size by 1 point
        font = ImageFont.truetype(font_path, font_size)
        draw = ImageDraw.Draw(img)
        max_text_width = max(draw.textlength(line, font=font) for line in text.split('\n'))

    # Split text into lines and calculate total height
    lines = text.split('\n')
    total_text_height = font_size * len(lines) + 10 * (len(lines) - 1)  # 10 pixels space between lines

    # Create a new image with additional white space for the text
    bar_height = total_text_height + 20  # 20 pixels extra margin top and bottom
    new_height = original_height + bar_height
    new_image = Image.new("RGB", (original_width, new_height), "white")
    new_image.paste(img, (0, 0))

    # Insert text into the white space
    draw = ImageDraw.Draw(new_image)
    current_height = original_height + 10  # Start a bit below the original image
    for line in lines:
        line_width = draw.textlength(line, font=font)
        x_position = (original_width - line_width) / 2
        draw.text((x_position, current_height), line, fill="black", font=font)
        current_height += font_size + 10  # Add spacing for the next line

    # Save the result
    new_image_path = f"{ssid}.png"
    new_image.save(new_image_path)
    print(f"QR code with text successfully created and saved as '{new_image_path}'.")

# Execute the function
create_wifi_qr_with_text()

