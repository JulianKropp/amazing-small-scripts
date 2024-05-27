# Wi-Fi QR Code Generator

This script allows you to create a QR code for your webside that. Below, the script will add the URL as text. This is particularly useful for printing and easy scanning to open the webise.

## Installation

To run this script, you need Python installed on your system. This guide will cover setting up a virtual environment for Python and running the script within it.

### Step 1: Clone the Repository

First, clone the repository or download the script to your local machine. Ensure it's named `main.py`.

### Step 2: Set Up a Virtual Environment

Navigate to the directory where you've placed the script and create a virtual environment. To do this, run:

```bash
python3 -m venv venv
```

This command creates a new directory named `venv` where the virtual environment files are stored.

### Step 3: Activate the Virtual Environment

Before installing dependencies, you need to activate the virtual environment. Use the appropriate command for your operating system:

- **Windows:**

```bash
venv\Scripts\activate
```

- **macOS/Linux:**

```bash
source venv/bin/activate
```

### Step 4: Install Dependencies

This script requires the `qrcode` and `Pillow` libraries. Install them using pip:

```bash
pip install qrcode[pil] Pillow
```

### Step 5: Download the Arial Font

The script uses Arial.ttf for text rendering. Download the font from the following URL and place it in the same directory as the script:

[Download Arial.ttf](https://github.com/matomo-org/travis-scripts/raw/master/fonts/Arial.ttf)

### Running the Script

With the virtual environment activated and dependencies installed, you can now run the script:

```bash
python main.py
```

Follow the on-screen prompts to enter your webside url. The script will generate a PNG image with the QR code and text information.

## Deactivating the Virtual Environment

When you're done, you can deactivate the virtual environment by running:

```bash
deactivate
```

This will return you to your global Python environment.
