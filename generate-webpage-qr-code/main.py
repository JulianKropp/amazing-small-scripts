import qrcode
from PIL import Image, ImageDraw, ImageFont

def generate_qr_code(url, font_path='Arial.ttf', output_file='wifi_qr_code.png'):
    # Generate the QR code
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )
    qr.add_data(url)
    qr.make(fit=True)

    qr_img = qr.make_image(fill_color="black", back_color="white")

    # Load font
    try:
        font = ImageFont.truetype(font_path, 20)
    except IOError:
        print(f"Font file not found: {font_path}")
        return

    # Create an image with space for the QR code and text
    text_width, text_height = font.getsize(url) if hasattr(font, 'getsize') else font.getbbox(url)[2:4]
    qr_width, qr_height = qr_img.size
    total_width = qr_width
    total_height = qr_height + text_height + 10  # Add some space between QR code and text

    img = Image.new('RGB', (total_width, total_height), 'white')
    draw = ImageDraw.Draw(img)

    # Paste the QR code onto the image
    img.paste(qr_img, (0, 0))

    # Draw the URL below the QR code
    text_position = ((total_width - text_width) // 2, qr_height + 10)
    draw.text(text_position, url, font=font, fill='black')

    # Save the final image
    img.save(output_file)
    print(f"QR code saved as {output_file}")

if __name__ == "__main__":
    url = input("Enter the website URL: ")
    generate_qr_code(url)
