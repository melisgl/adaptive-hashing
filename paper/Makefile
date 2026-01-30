.PHONY: all paper.pdf clean distclean arxiv

all: paper.pdf

paper.pdf:
	latexmk -e '$$max_repeat=5' -pdf -shell-escape \
		-interaction=nonstopmode \
		-halt-on-error -file-line-error paper.tex

clean:
	latexmk -c paper.tex

distclean: clean
	latexmk -C paper.tex
	rm -f *.bbl
	rm -f tikz/*.*

arxiv:
	tar cf ah-arxiv.tar *.tex *.sty *.bbl figure/*.png
