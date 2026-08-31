const checkbox = document.querySelector("#enabled");

chrome.storage.local.get("enabled").then(({ enabled }) => {
  checkbox.checked = enabled !== false;
});

checkbox.addEventListener("change", () => {
  chrome.storage.local.set({ enabled: checkbox.checked });
});
