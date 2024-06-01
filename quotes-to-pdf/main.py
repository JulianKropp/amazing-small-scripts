import pandas as pd
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages
import textwrap

# Lesen der CSV-Datei
df = pd.read_csv('quotes.csv', header=None, names=["Quote", "Author"])

# Einstellungen für das DIN A4 Blatt
page_width = 8.27
page_height = 11.69
margin = 0.2
font_size = 10
line_spacing = 0.2  # Adjusted to control spacing between lines
wrap_width = 80  # Adjust according to font size and page width

# Berechnung der maximalen Anzahl von Zitaten pro Seite
max_lines_per_page = int((page_height - 2 * margin) / line_spacing)

# Erstellen eines PDF-Dokuments
pdf_pages = PdfPages("quotes_output.pdf")

# Funktion zum Erstellen einer Seite mit Zitaten und Linien
def create_page(quotes):
    fig, ax = plt.subplots(figsize=(page_width, page_height))
    ax.set_xlim(0, page_width)
    ax.set_ylim(0, page_height)
    ax.axis("off")
    
    y = page_height - margin
    for quote, author in quotes:
        wrapped_quote = textwrap.fill(quote, wrap_width)
        lines = wrapped_quote.split('\n')
        lines.append(f"- {author}")
        
        for line in lines:
            ax.text(margin, y, line, fontsize=font_size, verticalalignment='top')
            y -= line_spacing
            if y < margin:
                pdf_pages.savefig(fig, bbox_inches="tight")
                plt.close()
                fig, ax = plt.subplots(figsize=(page_width, page_height))
                ax.set_xlim(0, page_width)
                ax.set_ylim(0, page_height)
                ax.axis("off")
                y = page_height - margin
        
        ax.plot([margin, page_width - margin], [y, y], color='black', linewidth=0.5)  # Zeichne Linie
        y -= line_spacing  # Platz für die Linie
    
    pdf_pages.savefig(fig, bbox_inches="tight")
    plt.close()

# Aufteilen der Zitate auf mehrere Seiten
quotes = []
line_count = 0

for index, row in df.iterrows():
    quote, author = row["Quote"], row["Author"]
    wrapped_quote = textwrap.fill(quote, wrap_width)
    lines = wrapped_quote.split('\n')
    lines.append(f"- {author}")
    lines_needed = len(lines) + 1  # +1 für die Linie
    
    if line_count + lines_needed > max_lines_per_page:
        create_page(quotes)
        quotes = []
        line_count = 0
        
    quotes.append((quote, author))
    line_count += lines_needed

if quotes:
    create_page(quotes)

# Schließen des PDF-Dokuments
pdf_pages.close()
