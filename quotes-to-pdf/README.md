# Quotes to PDF Project

This project reads quotes from a CSV file and generates a formatted PDF document with the quotes and their authors. Each quote is wrapped to fit within the page width, and quotes are split across multiple pages if necessary.

## Prerequisites

Before running the project, ensure you have the following installed:
- Python 3.6 or higher

## Setting Up a Virtual Environment

To set up a virtual environment for this project, follow these steps:

1. **Install `virtualenv`** (if not already installed):
   ```bash
   pip install virtualenv
   ```

2. **Create a virtual environment**:
   ```bash
   virtualenv venv
   ```

3. **Activate the virtual environment**:
   - On Windows:
     ```bash
     venv\Scripts\activate
     ```
   - On macOS and Linux:
     ```bash
     source venv/bin/activate
     ```

4. **Install the required dependencies**:
   ```bash
   pip install -r requirements.txt
   ```

## Running the Script

1. Place your quotes in a CSV file named `quotes.csv` in the same directory as the script. The CSV should have two columns: "Quote" and "Author", without a header row.

2. Run the script:
   ```bash
   python main.py
   ```

The script will generate a PDF file named `quotes_output.pdf` in the same directory.

## Requirements

The project dependencies are listed in the `requirements.txt` file:
```
pandas==2.0.2
matplotlib==3.7.1
```

## Script Explanation

- **Reading the CSV File**:
  The script reads the CSV file containing the quotes and authors using `pandas`.

- **Page Settings**:
  The page dimensions and formatting settings are defined to fit quotes neatly on a DIN A4 page.

- **PDF Generation**:
  The script uses `matplotlib` to create a PDF. It wraps long quotes to fit the page width and splits the content across multiple pages if necessary. Each quote is followed by a line and the author's name.

- **Handling Multiple Pages**:
  If the quotes exceed the space on a single page, the script creates a new page and continues adding quotes.

- **Saving the PDF**:
  The completed PDF is saved as `quotes_output.pdf`.

## Acknowledgements

- [Pandas](https://pandas.pydata.org/)
- [Matplotlib](https://matplotlib.org/)