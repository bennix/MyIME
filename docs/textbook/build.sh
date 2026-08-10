#!/bin/zsh
set -euo pipefail

cd "${0:A:h}"
mkdir -p ../../output/pdf ../../tmp/pdfs/textbook-render
mpost figures.mp
xelatex -interaction=nonstopmode -halt-on-error main.tex
makeindex main.idx
xelatex -interaction=nonstopmode -halt-on-error main.tex
xelatex -interaction=nonstopmode -halt-on-error main.tex
cp main.pdf ../../output/pdf/MyIME-Textbook.pdf
(cd ../../output/pdf && shasum -a 256 MyIME-Textbook.pdf > MyIME-Textbook.pdf.sha256)
pdfinfo ../../output/pdf/MyIME-Textbook.pdf | sed -n '1,20p'
