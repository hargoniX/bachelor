// This theme is inspired by https://github.com/matze/mtheme
// The polylux-port was performed by https://github.com/Enivex
#import "@preview/polylux:0.3.1": *

#let g-primary = rgb("#7d37f0")

#let g-foreground = rgb("#0f234b")
#let g-background = rgb("#ffffff")

#let g-footer = state("g-footer", [])

#let g-cell = block.with(
  width: 100%,
  height: 100%,
  above: 0pt,
  below: 0pt,
  breakable: false
)

#let genua-theme(
  aspect-ratio: "16-9",
  footer: [],
  body
) = {
  set page(
    paper: "presentation-" + aspect-ratio,
    fill: g-background,
    margin: 0em,
    header: none,
    footer: none,
  )

  g-footer.update(footer)

  body
}

#let title-slide(
  title: [],
  subtitle: none,
  author: none,
  date: none,
  extra: none,
  logo_institution: none,
  logo_company: none,
  logo_size: 0%,
) = {
  let content = {
    set text(fill: g-foreground)
    set align(center + horizon)
    block(width: 100%, inset: 2em, {
      grid(
        columns: (50%, 50%),
        align(center + horizon, image(logo_company, width: logo_size)),
        align(center + horizon, image(logo_institution, width: logo_size)),
      )
      text(size: 1.3em, strong(title))
      if subtitle != none {
        linebreak()
        text(size: 0.9em, subtitle)
      }
      line(length: 100%, stroke: .05em + g-primary)
      set text(size: .8em)
      if author != none {
        block(spacing: 1em, author)
      }
      if date != none {
        block(spacing: 1em, date)
      }
      set text(size: .8em)
      if extra != none {
        block(spacing: 1em, extra)
      }
    })
  }

  logic.polylux-slide(content)
}

#let slide(title: none, body) = {
  let header = {
    set align(top)
    if title != none {
      show: g-cell.with(fill: g-primary, inset: 1.2em)
      set align(horizon)
      set text(fill: g-background, size: 1.2em)
      strong(title)
    } else { [] }
  }

  let footer = {
    set text(size: 0.8em)
    show: pad.with(.5em)
    set align(bottom)
    text(fill: g-foreground, g-footer.display())
    h(1fr)
    text(fill: g-foreground, logic.logical-slide.display())
  }

  set page(
    header: header,
    footer: footer,
    margin: (top: 5em, bottom: 0em),
    fill: g-background,
  )

  let content = {
    show: align.with(horizon)
    show: pad.with(2em)
    set text(fill: g-foreground)
    body
  }

  logic.polylux-slide(content)
}

#let new-section-slide(name) = {
  let content = {
    utils.register-section(name)
    set align(horizon)
    show: pad.with(20%)
    set text(size: 1.5em)
    name
  }
  logic.polylux-slide(content)
}

#let focus-slide(body) = {
  set page(fill: g-foreground, margin: 2em)
  set text(fill: g-background, size: 1.5em)
  logic.polylux-slide(align(horizon + center, body))
}

#let genua-outline = utils.polylux-outline(enum-args: (tight: false,))
