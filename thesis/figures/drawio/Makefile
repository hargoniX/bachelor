all: verix-arch.drawio.pdf.svg rx-queue.drawio.pdf.svg

%.pdf.svg : %.pdf
	pdf2svg $< $<.svg

%.pdf : %.xml
	drawio --export --format=pdf --crop $<

clean:
	rm -rf *.pdf
	rm -rf *.svg

.PHONY: clean
