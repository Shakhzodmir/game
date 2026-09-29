"""GLOW v2 palette - the single place for the colours of docs/design/art-direction.md."""

# pieces: (light, base, shadow, outline)
PIECES = {
    "red": ("#FF8FAE", "#FF4468", "#E0183F", "#B3122F"),
    "orange": ("#FFD08A", "#FF9A1F", "#F07400", "#C25700"),
    "yellow": ("#FFF7B0", "#FFDB1A", "#F5B800", "#C28A00"),
    "green": ("#A8FFD4", "#2BE38F", "#10B96A", "#0A8A4F"),
    "blue": ("#A9DCFF", "#3AA4FF", "#1775E8", "#0B55B8"),
    "purple": ("#D9B8FF", "#9B52FF", "#7426E8", "#5B17C9"),
}
ORDER = ["red", "orange", "yellow", "green", "blue", "purple"]

PIECE_SHADOW = "#5A3FA0"          # soft drop shadow under pieces, 30-35 %

# specials
RIFF_GLOW, RIFF_LINE = "#1FD1FF", "#1FA8E6"
SUB_TOP, SUB_BOT, SUB_CONE, SUB_ACCENT = "#7B6BFF", "#4B3BD6", "#FF6FD8", "#FFDB1A"
BIRD_A, BIRD_B, BIRD_WING, BIRD_BEAK = "#7EF0FF", "#1FA8E6", "#B6FF3B", "#FFB020"
DISCO_HI, DISCO_LO = "#FFFFFF", "#B7C2DC"

# board
CELL_A, CELL_B = "#FFFFFF", "#EFE8FF"
FRAME_GLOW = (155 / 255, 82 / 255, 1.0)       # rgba(155,82,255,0.25)
FRAME_SHADOW = (47 / 255, 128 / 255, 237 / 255)  # rgba(47,128,237,0.3)
FLOOR, FLOOR_LIT_A, FLOOR_LIT_B = "#D8CCFF", "#FFF6B8", "#FFD23F"
NOISE = "#8A8FA3"
WIRE, WIRE_CORE = "#5B4B7A", "#FFB463"
CARD, CARD_DARK = "#FFB463", "#C56A1C"

# sky / town
SKY = [(0.0, "#43BFFF"), (0.38, "#86DDFF"), (0.70, "#C9F2FF"), (1.0, "#FFF4C9")]
TOWN = ["#FF9EC7", "#FFD36E", "#8BE39A", "#7FC8FF", "#C9A7FF"]
CONCERT = [(0.0, "#3B2A8F"), (1.0, "#6B4CE0")]
SPOTS = ["#FF4FD8", "#3CF2FF", "#FFE66D"]

# ui
INK = "#2B2345"
BUTTONS = {   # top, bottom, shelf
    "green": ("#6CF08E", "#22C55E", "#15964A"),
    "blue": ("#5CD6FF", "#2F80ED", "#1C5FC0"),
    "gold": ("#FFD84D", "#FFA41B", "#E07F00"),
    "pink": ("#FF7EB6", "#FF4D8D", "#D62F6C"),
    "purple": ("#C18CFF", "#8B45FF", "#6A2FD6"),
}
PANEL_LINE = "#E6DAFF"
PINK_BADGE = [(0.0, "#FF8FC7"), (0.6, "#FF4D8D"), (1.0, "#F0306F")]

# mascot Bit
BIT_FUR, BIT_LINE = "#FFC98B", "#E0873A"
BIT_PHONES, BIT_CUPS, BIT_LIGHTS = "#7B4FFF", "#FF4D8D", "#FFDB1A"
