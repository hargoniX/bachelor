#import "@preview/glossarium:0.1.0": make-glossary, print-glossary, gls, glspl
#import "@preview/bytefield:0.0.2": bytefield, bit, bits, bytes, flagtext
#import "@preview/ctheorems:1.0.0": *

#let theorem = thmplain("theorem", "Theorem")
#let definition = thmplain("definition", "Definition")
#let proof = thmplain(
  "proof",
  "Proof",
  base: "theorem",
  bodyfmt: body => [#body #h(1fr) $square$]
).with(numbering: none)

#let bfield(..args) = [
  #set text(7pt);
  #bytefield(msb_first: true, ..args);
]

#let buildMainHeader(mainHeadingContent) = {
  [
    #align(center, smallcaps(mainHeadingContent))
    #line(length: 100%)
  ]
}

#let buildSecondaryHeader(mainHeadingContent, secondaryHeadingContent) = {
  [
    #smallcaps(mainHeadingContent)  #h(1fr)  #emph(secondaryHeadingContent)
    #line(length: 100%)
  ]
}

// To know if the secondary heading appears after the main heading
#let isAfter(secondaryHeading, mainHeading) = {
  let secHeadPos = secondaryHeading.location().position()
  let mainHeadPos = mainHeading.location().position()
  if (secHeadPos.at("page") > mainHeadPos.at("page")) {
    return true
  }
  if (secHeadPos.at("page") == mainHeadPos.at("page")) {
    return secHeadPos.at("y") > mainHeadPos.at("y")
  }
  return false
}

#let getHeader() = {
  locate(loc => {
    // Find if there is a level 1 heading on the current page
    let nextMainHeading = query(selector(heading).after(loc), loc).find(headIt => {
     headIt.location().page() == loc.page() and headIt.level == 1
    })
    if (nextMainHeading != none) {
      return buildMainHeader(nextMainHeading.body)
    }
    // Find the last previous level 1 heading -- at this point surely there's one :-)
    let lastMainHeading = query(selector(heading).before(loc), loc).filter(headIt => {
      headIt.level == 1
    }).last()
    // Find if the last level > 1 heading in previous pages
    let previousSecondaryHeadingArray = query(selector(heading).before(loc), loc).filter(headIt => {
      headIt.level > 1
    })
    let lastSecondaryHeading = if (previousSecondaryHeadingArray.len() != 0) {previousSecondaryHeadingArray.last()} else {none}
    // Find if the last secondary heading exists and if it's after the last main heading
    if (lastSecondaryHeading != none and isAfter(lastSecondaryHeading, lastMainHeading)) {
      return buildSecondaryHeader(lastMainHeading.body, lastSecondaryHeading.body)
    }
    return buildMainHeader(lastMainHeading.body)
  })
}

#let thesis(
    title: "This is my title",
    name: "",
    email: "",
    matriculation: "",
    abstract: none,
    paper-size: "a4",
    bibliography-file: none,
    glossary: (),
    supervisor_institution: "",
    supervisor_company: "",
    institution: "",
    logo_company: none,
    logo_institution: none,
    logo_size: 0%,
    submition_date: "",
    body
) = {
    set document(title: title, author: name)
    set text(font: "New Computer Modern", size: 11pt, lang: "en")
    set page(paper: paper-size)
    set heading(numbering: "1.1")
    set par(justify: true)
    show: make-glossary
    show link: set text(fill: blue.darken(60%))
    show outline.entry.where(
      level: 1
    ): it => {
      v(12pt, weak: true)
      strong(it)
    }
    show: thmrules
    show raw: set text(font: "JuliaMono", size: 9pt)

    // Logo
    v(5%)
    grid(
      columns: (50%, 50%),
      align(center + horizon, image(logo_institution, width: logo_size)),
      align(center + horizon, image(logo_company, width: logo_size)),
    )

    // Institution
    v(5%)
    align(center)[
      #text(1.5em, weight: 400, institution)
    ]

    // Title page
    v(3%)
    line(length: 100%)
    align(center)[
      #text(2em, weight: 500, title)
    ]
    line(length: 100%)

    // Author information
    v(1fr) // push to bottom
    grid(
      columns: (1fr),
      gutter: 1em,
      align(center)[
        *#name* \
        #email \
        #matriculation \
        #supervisor_institution \
        #supervisor_company
      ],
    )

    // Submition date
    v(2%)
    align(center, submition_date)

    pagebreak()

    // Abstract page.
    set page(numbering: "I", number-align: center)
    align(center)[
      #heading(
        outlined: false,
        numbering: none,
        text(0.85em, smallcaps[Abstract]),
      )
    ]
    abstract
    counter(page).update(1)
    pagebreak()

    // Table of contents.
    outline(depth: 3, indent: true)
    pagebreak()



    // Main body.
    set page(numbering: "1", number-align: center)
    set page(header: getHeader())
    counter(page).update(1)

    body

    pagebreak(weak: true)
    bibliography(bibliography-file, title: [References])


    pagebreak(weak: true)
    set heading(numbering: "A.1")
    counter(heading).update(0)
    heading("Appendix", level: 1)
    heading("Glossary", level: 2)
    print-glossary(glossary)

    heading("List of Figures", level: 2)
    outline(
      title: none,
      depth: 3, indent: true,
      target: figure.where(kind: image),
    )

    heading("List of Tables", level: 2)
    outline(
      title: none,
      depth: 3, indent: true,
      target: figure.where(kind: table)
    )
}
