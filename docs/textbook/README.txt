《从零实现 macOS 中文输入法》构建说明

在本目录运行：

  mpost figures.mp
  xelatex -interaction=nonstopmode main.tex
  makeindex main.idx
  xelatex -interaction=nonstopmode main.tex
  xelatex -interaction=nonstopmode main.tex

也可以运行：

  ./build.sh

教材源码通过 lstinputlisting 引用仓库中的实际 MyIME 源文件，因此请保留当前目录结构。
最终 PDF 会复制到 ../../output/pdf/MyIME-Textbook.pdf。
