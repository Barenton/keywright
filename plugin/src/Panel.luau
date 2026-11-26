--!strict
-- The plugin's panel: what it shows and how it is laid out. What the panel does, and when,
-- is decided in Main; this only draws it.
--
-- The panel can be docked anywhere in Studio, so it may be a narrow column beside the
-- Explorer, a wide strip under the viewport, or a small floating window. Things that can
-- sit side by side do so while they fit, sharing out the width between them, and go one
-- above the other when they do not: Studio's flex layout decides, at every width, so no
-- width leaves a gap beside them. Text wraps rather than being cut off, the whole panel
-- scrolls when it is taller than its window, and on a wide panel everything stops at a
-- width that still reads as lines. Its colours are Studio's own, and follow Studio when
-- the theme is changed.

local Panel = {}

export type Tone = "off" | "busy" | "ready" | "problem"

export type View = {
	toggle: TextButton,
	approve: TextButton,
	reject: TextButton,
	setAccess: (on: boolean) -> (),
	setStatus: (text: string, tone: Tone) -> (),
	setPairing: (command: string?) -> (),
	setNote: (text: string) -> (),
	setProposal: (text: string?) -> (),
	setOutcome: (text: string) -> (),
	addNotice: (text: string) -> (),
	setVersion: (text: string) -> (),
	destroy: () -> (),
}

local MARGIN = 12
local GAP = 10
local TEXT_SIZE = 15
local SMALL_TEXT_SIZE = 13
-- Lines longer than this are hard to read, so text stops here on a wide panel.
local TEXT_WIDTH = 560
local BUTTON_HEIGHT = 30
-- The narrowest each part of a row is before it grows into the room left: below the sum
-- of them, the row's parts go one above the other, each then as wide as the panel.
local STATUS_WIDTH = 200
local TOGGLE_WIDTH = 190
local CHOICE_WIDTH = 150
local SCROLL_BAR = 6

-- What the panel says about the connection in each of its states, and the colour of the
-- dot beside it.
function Panel.describe(state: string, detail: string?): (string, Tone)
	if state == "ready" then
		return "Connected to the broker.", "ready"
	elseif state == "connecting" then
		return "Connecting to the broker...", "busy"
	elseif state == "unpaired" then
		return if detail then "Waiting for the pairing code to be registered." else "Not paired with the broker.",
			"busy"
	elseif state == "foreign" then
		return "Another program is using the broker port. Nothing was sent to it.", "problem"
	elseif state == "denied" and detail == "plugin_older" then
		return 'This plugin is older than the Keywright adapter, and the two cannot work together. Update the plugin: run "npm run install:plugin" in the keywright folder.',
			"problem"
	elseif state == "denied" and detail == "adapter_older" then
		return "The Keywright adapter is older than this plugin, and the two cannot work together. Update the adapter (git pull, npm install, npm run build in the keywright folder), then reconnect it in your AI app.",
			"problem"
	elseif state == "denied" then
		return `The broker refused the connection ({detail or "unknown"}).`, "problem"
	elseif state == "stopped" then
		return "Agent access is off.", "off"
	end
	return "Broker not reachable. Retrying...", "problem"
end

local function studioTheme(): StudioTheme
	return settings().Studio.Theme
end

local function color(name: Enum.StudioStyleGuideColor, modifier: Enum.StudioStyleGuideModifier?): Color3
	return studioTheme():GetColor(name, modifier or Enum.StudioStyleGuideModifier.Default)
end

-- Whether the theme is a dark one, from how light its background is.
local function dark(): boolean
	local background = color(Enum.StudioStyleGuideColor.MainBackground)
	return 0.2126 * background.R + 0.7152 * background.G + 0.0722 * background.B < 0.5
end

local function pad(item: Instance, vertical: number, horizontal: number)
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, vertical)
	padding.PaddingBottom = UDim.new(0, vertical)
	padding.PaddingLeft = UDim.new(0, horizontal)
	padding.PaddingRight = UDim.new(0, horizontal)
	padding.Parent = item
end

local function rounded(item: Instance, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = item
end

-- A part of a row that grows into the room the row has left, sharing it evenly with the
-- others, and shrinks when it is alone on a line narrower than it.
local function flexible(item: GuiObject)
	local flex = Instance.new("UIFlexItem")
	flex.FlexMode = Enum.UIFlexMode.Fill
	flex.Parent = item
end

-- A row whose parts wrap onto lines of their own when they do not fit side by side.
local function row(parent: Instance, gap: number): UIListLayout
	local items = Instance.new("UIListLayout")
	items.SortOrder = Enum.SortOrder.LayoutOrder
	items.FillDirection = Enum.FillDirection.Horizontal
	items.Wraps = true
	items.Padding = UDim.new(0, gap)
	items.VerticalAlignment = Enum.VerticalAlignment.Center
	items.ItemLineAlignment = Enum.ItemLineAlignment.Center
	items.Parent = parent
	return items
end

local function edged(item: Instance): UIStroke
	local edge = Instance.new("UIStroke")
	edge.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	edge.Parent = item
	return edge
end

function Panel.new(widget: DockWidgetPluginGui): View
	local BODY = Font.fromEnum(Enum.Font.BuilderSans)
	local STRONG = Font.fromEnum(Enum.Font.BuilderSansBold)
	local CODE = Font.fromEnum(Enum.Font.RobotoMono)

	-- Everything whose colour comes from the theme, painted again when the theme changes.
	local painters: { () -> () } = {}
	local function painted(paint: () -> ())
		table.insert(painters, paint)
		paint()
	end

	local frame = Instance.new("ScrollingFrame")
	frame.Name = "Keywright"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BorderSizePixel = 0
	frame.ScrollingDirection = Enum.ScrollingDirection.Y
	frame.ScrollBarThickness = SCROLL_BAR
	-- The scroll bar takes its own room, beside what it scrolls, instead of covering it.
	frame.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	frame.CanvasSize = UDim2.new()
	painted(function()
		frame.BackgroundColor3 = color(Enum.StudioStyleGuideColor.MainBackground)
		frame.ScrollBarImageColor3 = color(Enum.StudioStyleGuideColor.ScrollBar)
	end)

	pad(frame, MARGIN, MARGIN)

	-- Items appear in the order given to them, not in the order of their names: a list
	-- sorted by name once put every button above every label, which left the buttons for
	-- a proposal on screen and the text explaining them out of sight.
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, GAP)
	layout.Parent = frame

	-- The canvas is as tall as what is in it with the margins, which the canvas's own
	-- automatic size does not count.
	local function fit()
		frame.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 2 * MARGIN)
	end
	local fitting = layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)

	local function widest(item: GuiObject, width: number)
		local limit = Instance.new("UISizeConstraint")
		limit.MaxSize = Vector2.new(width, math.huge)
		limit.Parent = item
	end

	local function group(order: number, parent: Instance?): Frame
		local item = Instance.new("Frame")
		item.Size = UDim2.fromScale(1, 0)
		item.AutomaticSize = Enum.AutomaticSize.Y
		item.BackgroundTransparency = 1
		item.LayoutOrder = order
		item.Parent = parent or frame
		return item
	end

	local function list(parent: Instance, gap: number): UIListLayout
		local items = Instance.new("UIListLayout")
		items.SortOrder = Enum.SortOrder.LayoutOrder
		items.Padding = UDim.new(0, gap)
		items.Parent = parent
		return items
	end

	-- A line of text, as tall as its text needs. It is hidden while it has no text, so
	-- that it takes no room and leaves no gap in the list.
	local function text(order: number, parent: Instance?, size: number?): TextLabel
		local item = Instance.new("TextLabel")
		item.Size = UDim2.fromScale(1, 0)
		item.AutomaticSize = Enum.AutomaticSize.Y
		item.BackgroundTransparency = 1
		item.FontFace = BODY
		item.TextSize = size or TEXT_SIZE
		item.TextWrapped = true
		item.TextXAlignment = Enum.TextXAlignment.Left
		item.TextYAlignment = Enum.TextYAlignment.Top
		item.Text = ""
		item.Visible = false
		item.LayoutOrder = order
		painted(function()
			item.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
		end)
		widest(item, TEXT_WIDTH)
		item.Parent = parent or frame
		return item
	end

	local function say(item: TextLabel, words: string)
		item.Text = words
		item.Visible = words ~= ""
	end

	-- A button in Studio's colours, lighter under the pointer and darker while pressed.
	-- The main one of a choice is in the colour of a dialog's main button. The text wraps
	-- on a narrow panel, and the button grows to hold it.
	local mains: { [TextButton]: boolean } = {}
	local buttonPainters: { [TextButton]: () -> () } = {}
	local function button(words: string, order: number, parent: Instance?, main: boolean?): TextButton
		local item = Instance.new("TextButton")
		item.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
		item.AutomaticSize = Enum.AutomaticSize.Y
		item.AutoButtonColor = false
		item.FontFace = BODY
		item.TextSize = TEXT_SIZE
		item.TextWrapped = true
		item.Text = words
		item.LayoutOrder = order
		mains[item] = main == true
		pad(item, 5, 8)
		rounded(item, UDim.new(0, 4))
		local edge = edged(item)

		local modifier = Enum.StudioStyleGuideModifier.Default
		local function paint()
			local isMain = mains[item]
			local fill = if isMain
				then Enum.StudioStyleGuideColor.DialogMainButton
				else Enum.StudioStyleGuideColor.Button
			item.BackgroundColor3 = color(fill, modifier)
			item.TextColor3 = color(
				if isMain
					then Enum.StudioStyleGuideColor.DialogMainButtonText
					else Enum.StudioStyleGuideColor.ButtonText,
				modifier
			)
			edge.Color = color(if isMain then fill else Enum.StudioStyleGuideColor.ButtonBorder, modifier)
		end
		local function become(next: Enum.StudioStyleGuideModifier)
			modifier = next
			paint()
		end
		item.MouseEnter:Connect(function()
			become(Enum.StudioStyleGuideModifier.Hover)
		end)
		item.MouseLeave:Connect(function()
			become(Enum.StudioStyleGuideModifier.Default)
		end)
		item.MouseButton1Down:Connect(function()
			become(Enum.StudioStyleGuideModifier.Pressed)
		end)
		item.MouseButton1Up:Connect(function()
			become(Enum.StudioStyleGuideModifier.Hover)
		end)
		buttonPainters[item] = paint
		painted(paint)
		item.Parent = parent or frame
		return item
	end

	local function restyle(item: TextButton, main: boolean)
		mains[item] = main
		buttonPainters[item]()
	end

	-- A proposal waiting to be decided, at the top: what is asked, and the two answers
	-- directly below it, in a box that stands out from the rest of the panel.
	local card = group(10)
	card.Visible = false
	widest(card, TEXT_WIDTH)
	card.BackgroundTransparency = 0
	pad(card, 10, 10)
	rounded(card, UDim.new(0, 6))
	local cardEdge = edged(card)
	painted(function()
		card.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		cardEdge.Color = color(Enum.StudioStyleGuideColor.DialogMainButton)
	end)
	list(card, 8)
	local cardTitle = text(1, card)
	cardTitle.FontFace = STRONG
	say(cardTitle, "An agent is asking to replace a clip")
	local cardText = text(2, card)
	local choices = group(3, card)
	row(choices, 8)
	local approve = button("Replace the clip", 1, choices, true)
	local reject = button("Keep the clip as it is", 2, choices)
	for _, choice in { approve, reject } do
		choice.Size = UDim2.fromOffset(CHOICE_WIDTH, BUTTON_HEIGHT)
		flexible(choice)
	end
	local outcome = text(20)

	-- The connection's state: a coloured dot and a line saying what it is, beside the
	-- switch for agent access on a wide panel, above it on a narrow one.
	local header = group(30)
	-- Held to the width of the text, so that the switch stays near the words beside it.
	widest(header, TEXT_WIDTH)
	row(header, GAP)
	local statusRow = group(1, header)
	statusRow.Size = UDim2.fromOffset(STATUS_WIDTH, 0)
	flexible(statusRow)
	local dot = Instance.new("Frame")
	dot.Size = UDim2.fromOffset(8, 8)
	-- Its middle on the middle of the status's first line, a line being as tall as its text.
	dot.AnchorPoint = Vector2.new(0, 0.5)
	dot.Position = UDim2.fromOffset(0, math.ceil(TEXT_SIZE / 2))
	dot.BorderSizePixel = 0
	rounded(dot, UDim.new(0.5, 0))
	dot.Parent = statusRow
	local status = text(1, statusRow)
	status.Position = UDim2.fromOffset(16, 0)
	status.Size = UDim2.new(1, -16, 0, 0)
	status.FontFace = STRONG
	local tone: Tone = "off"
	local function paintDot()
		dot.BackgroundColor3 = if tone == "ready"
			then (if dark() then Color3.fromRGB(88, 196, 120) else Color3.fromRGB(28, 132, 64))
			elseif tone == "busy" then color(Enum.StudioStyleGuideColor.WarningText)
			elseif tone == "problem" then color(Enum.StudioStyleGuideColor.ErrorText)
			else color(Enum.StudioStyleGuideColor.DimmedText)
	end
	painted(paintDot)
	local toggle = button("Turn on agent access", 2, header, true)
	toggle.Size = UDim2.fromOffset(TOGGLE_WIDTH, BUTTON_HEIGHT)
	flexible(toggle)

	-- Pairing: the command to run, in a box it can be selected and copied from.
	local pairing = group(40)
	pairing.Visible = false
	list(pairing, 6)
	local pairingText = text(1, pairing)
	say(pairingText, "Pair once. Within 5 minutes, run this in a terminal, in the keywright folder:")
	local command = Instance.new("TextBox")
	command.Size = UDim2.fromScale(1, 0)
	command.AutomaticSize = Enum.AutomaticSize.Y
	command.FontFace = CODE
	command.TextSize = 14
	command.TextWrapped = true
	command.TextXAlignment = Enum.TextXAlignment.Left
	command.TextEditable = false
	command.ClearTextOnFocus = false
	command.LayoutOrder = 2
	pad(command, 6, 8)
	rounded(command, UDim.new(0, 4))
	local commandEdge = edged(command)
	widest(command, TEXT_WIDTH)
	painted(function()
		command.BackgroundColor3 = color(Enum.StudioStyleGuideColor.InputFieldBackground)
		command.TextColor3 = color(Enum.StudioStyleGuideColor.MainText)
		commandEdge.Color = color(Enum.StudioStyleGuideColor.InputFieldBorder)
	end)
	-- A click selects the whole command, ready to be copied.
	local selecting = command.Focused:Connect(function()
		command.SelectionStart = 1
		command.CursorPosition = #command.Text + 1
	end)
	command.Parent = pairing
	local copyHint = text(3, pairing, SMALL_TEXT_SIZE)
	say(copyHint, "Click the command to select it, then copy it with Ctrl+C (Cmd+C on a Mac).")
	painted(function()
		copyHint.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	end)

	-- Anything else to know about pairing, or about remembering access for this place.
	local note = text(50)
	-- Lines that stay, such as that this is a test build.
	local notices = 60
	-- At the bottom, which release this is: the first thing to know when the plugin and
	-- the adapter may not match.
	local version = text(1000, nil, SMALL_TEXT_SIZE)
	painted(function()
		version.TextColor3 = color(Enum.StudioStyleGuideColor.DimmedText)
	end)

	local repainting = settings().Studio.ThemeChanged:Connect(function()
		for _, paint in painters do
			paint()
		end
	end)

	frame.Parent = widget
	fit()

	local view: View
	view = {
		toggle = toggle,
		approve = approve,
		reject = reject,
		setAccess = function(on: boolean)
			toggle.Text = if on then "Turn off agent access" else "Turn on agent access"
			-- Turning access on is what the panel is there for; turning it off is not urged.
			restyle(toggle, not on)
		end,
		setStatus = function(words: string, next: Tone)
			tone = next
			say(status, words)
			paintDot()
		end,
		setPairing = function(line: string?)
			pairing.Visible = line ~= nil
			command.Text = line or ""
		end,
		setNote = function(words: string)
			say(note, words)
		end,
		setProposal = function(words: string?)
			card.Visible = words ~= nil
			say(cardText, words or "")
		end,
		setOutcome = function(words: string)
			say(outcome, words)
		end,
		addNotice = function(words: string)
			notices += 1
			say(text(notices), words)
		end,
		setVersion = function(words: string)
			say(version, words)
		end,
		destroy = function()
			fitting:Disconnect()
			repainting:Disconnect()
			selecting:Disconnect()
			frame:Destroy()
		end,
	}
	return view
end

return Panel
