extends RefCounted
## UX round (P5) UI palette: the colours and sizes of the Apalit UI theme
## (`apalit_theme.tres` uses the same values) for UI drawn or tinted in code, so code
## and theme stay one look. Presentation only.

const PANEL := Color(0.09, 0.10, 0.12, 0.92)
const CONTROL := Color(0.15, 0.16, 0.19)
const CONTROL_HOVER := Color(0.20, 0.22, 0.26)
const CONTROL_PRESSED := Color(0.12, 0.30, 0.38)
const BORDER := Color(0.28, 0.31, 0.36)
const ACCENT := Color(0.30, 0.75, 0.90)
const TEXT := Color(0.88, 0.90, 0.92)
const TEXT_MUTED := Color(0.60, 0.64, 0.69)
const TEXT_DISABLED := Color(0.42, 0.45, 0.49)
const WARNING := Color(0.95, 0.70, 0.25)
const DANGER := Color(0.88, 0.44, 0.35)
const SUCCESS := Color(0.49, 0.76, 0.49)

const SPACING := 6 # px between rows and controls
const RADIUS := 3 # px corner radius
const BORDER_WIDTH := 1 # px
