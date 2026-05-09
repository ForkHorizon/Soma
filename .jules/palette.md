## 2024-05-23 - [Add accessibility label to input field and help tooltips to buttons]
**Learning:** Found custom text inputs with placeholder text that lack accessibility labeling, and buttons whose states and shortcuts were unclear without tooltips.
**Action:** Always add `.accessibilityHidden(true)` on visual placeholders and `.accessibilityLabel()` on the actual `TextEditor` field. Add `.help()` tooltips to explain button functionality, states (disabled), and keyboard shortcuts.
