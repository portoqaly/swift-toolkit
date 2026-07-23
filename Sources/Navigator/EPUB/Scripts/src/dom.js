//
//  Copyright 2025 Readium Foundation. All rights reserved.
//  Use of this source code is governed by the BSD-style license
//  available in the top-level LICENSE file of the project.
//

import { isScrollModeEnabled } from "./utils";
import { getCssSelector } from "css-selector-generator";

// Returns `element` or its first parent that is considered "user interactive".
// For example a link, a video clip or a text field.
//
// See. https://github.com/JayPanoz/architecture/tree/touch-handling/misc/touch-handling
export function findNearestInteractiveElement(element) {
  if (element == null) {
    return null;
  }

  var interactiveTags = [
    "a",
    "audio",
    "button",
    "canvas",
    "details",
    "input",
    "label",
    "option",
    "select",
    "submit",
    "textarea",
    "video",
  ];
  if (interactiveTags.indexOf(element.nodeName.toLowerCase()) !== -1) {
    return element.outerHTML;
  }

  // Checks whether the element is editable by the user.
  if (
    element.hasAttribute("contenteditable") &&
    element.getAttribute("contenteditable").toLowerCase() != "false"
  ) {
    return element.outerHTML;
  }

  // Checks parents recursively because the touch might be for example on an <em> inside a <a>.
  if (element.parentElement) {
    return findNearestInteractiveElement(element.parentElement);
  }

  return null;
}

/// Returns the `Locator` object to the first block element that is visible on
/// the screen.
export function findFirstVisibleLocator() {
  return findFirstVisibleLocatorInViewport(0, window.innerHeight);
}

/// Returns the first block element intersecting an explicit vertical viewport.
///
/// Continuous scroll keeps each resource's WebView fully expanded and scrolls
/// a native parent view, so `window.scrollY` is always zero. Native code passes
/// the visible slice of the resource to preserve element-level locators.
export function findFirstVisibleLocatorInViewport(top, height) {
  const viewport = {
    top: Math.max(0, top),
    bottom: Math.max(0, top) + Math.max(1, height),
  };
  const element = findElement(document.body, viewport);
  return {
    href: "#",
    type: "application/xhtml+xml",
    locations: {
      cssSelector: getCssSelector(element),
    },
    text: {
      highlight: element.textContent,
    },
  };
}

function findElement(rootElement, viewport) {
  for (var i = 0; i < rootElement.children.length; i++) {
    const child = rootElement.children[i];
    if (!shouldIgnoreElement(child) && isElementVisible(child, viewport)) {
      return findElement(child, viewport);
    }
  }
  return rootElement;
}

function isElementVisible(element, viewport) {
  if (readium.isFixedLayout) return true;

  if (element === document.body || element === document.documentElement) {
    return true;
  }
  if (!document || !document.documentElement || !document.body) {
    return false;
  }

  const rect = element.getBoundingClientRect();
  if (viewport) {
    return rect.bottom > viewport.top && rect.top < viewport.bottom;
  }
  if (isScrollModeEnabled()) {
    return rect.bottom > 0 && rect.top < window.innerHeight;
  } else {
    return rect.right > 0 && rect.left < window.innerWidth;
  }
}

function shouldIgnoreElement(element) {
  const elStyle = getComputedStyle(element);
  if (elStyle) {
    const display = elStyle.getPropertyValue("display");
    if (display != "block") {
      return true;
    }
    // Cannot be relied upon, because web browser engine reports invisible when out of view in
    // scrolled columns!
    // const visibility = elStyle.getPropertyValue("visibility");
    // if (visibility === "hidden") {
    //     return false;
    // }
    const opacity = elStyle.getPropertyValue("opacity");
    if (opacity === "0") {
      return true;
    }
  }

  return false;
}
