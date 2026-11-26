for (const widget of document.querySelectorAll(".pse-connect")) {
  const button = widget.querySelector("button");
  const label = widget.querySelector(".pse-connect-label");
  const status = widget.querySelector('[role="status"]');
  const manual = widget.querySelector("details");
  const field = manual.querySelector("pre");
  const idleLabel = label.textContent;
  let reset;
  button.hidden = false;
  manual.hidden = true;

  button.addEventListener("click", async () => {
    clearTimeout(reset);
    let copied = false;
    try {
      await navigator.clipboard.writeText(field.textContent);
      copied = true;
    } catch {
      // Local files and restricted browsers may only support selection-based copy.
      manual.hidden = false;
      manual.open = true;
      field.focus({preventScroll: true});
      const range = document.createRange();
      range.selectNodeContents(field);
      const selection = window.getSelection();
      selection.removeAllRanges();
      selection.addRange(range);
      try { copied = document.execCommand("copy"); } catch { /* Leave text selected. */ }
    }
    button.classList.toggle("is-copied", copied);
    label.textContent = copied ? "Prompt copied" : idleLabel;
    status.textContent = copied
      ? "Paste the prompt into your coding agent."
      : "Copy the selected prompt and paste it into your coding agent.";
    if (copied) {
      if (!manual.hidden) {
        window.getSelection().removeAllRanges();
        button.focus({preventScroll: true});
      }
      manual.hidden = true;
      reset = setTimeout(() => {
        button.classList.remove("is-copied");
        label.textContent = idleLabel;
        status.textContent = "";
      }, 3500);
    }
  });
}
