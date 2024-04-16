.PHONY: all talk.pdf clean distclean

all: talk.pdf

talk.pdf:
	latexmk -e '$$max_repeat=5' -pdf -shell-escape \
		-interaction=nonstopmode \
		-halt-on-error -file-line-error talk.tex

clean:
	latexmk -c talk.tex

distclean: clean
	latexmk -C talk.tex
	rm -f *.bbl
	rm -f tikz/*.*
