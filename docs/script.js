const examples = {
  xiaozhuzaishuiliyouyong: ["小猪在水里游泳", "小猪在水里有用", "小住在水里游泳"],
  xiaogouzhuihudie: ["小狗追蝴蝶", "小狗追蝴蝶。", "小狗追蝴蝶🦋"],
  jinwanchigefan: ["今晚吃个饭", "今晚吃个饭吧", "今晚吃个饭？"],
  aisinile: ["爱死你了", "爱死你啦", "爱死你咯"],
  shuru: ["输入", "熟肉", "书如"]
};

const input = document.querySelector("#pinyin-demo");
const list = document.querySelector("#candidate-list");

function candidatesFor(value) {
  const normalized = value.toLowerCase().replace(/[^a-z']/g, "");
  if (examples[normalized]) return examples[normalized];
  const related = Object.keys(examples).find(key => key.startsWith(normalized) || normalized.startsWith(key));
  return related ? examples[related] : [normalized || "开始输入", "本地候选", "智能组词"];
}

function renderCandidates() {
  list.replaceChildren(...candidatesFor(input.value).map((candidate, index) => {
    const item = document.createElement("li");
    const number = document.createElement("small");
    number.textContent = String(index + 1);
    item.append(number, candidate);
    return item;
  }));
}

input.addEventListener("input", renderCandidates);
document.querySelectorAll("[data-demo]").forEach(button => {
  button.addEventListener("click", () => {
    input.value = button.dataset.demo;
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
    renderCandidates();
  });
});

renderCandidates();
