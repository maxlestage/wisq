/// The full mark, for the one place on the site that has room for it.
///
/// A logo system rather than one drawing. The icon that goes on a Home Screen
/// is `▚` alone — two quadrants, no detail — because at 60 px anything more
/// becomes mush, and `scripts/icons.ts` draws exactly that. This is the same
/// mark with the room to say what the quadrants are: the upper-left one is a
/// window on a machine somewhere else, the lower-right one is the phone in
/// your hand, and the diagonal between them is the whole product.
///
/// Drawn in code, like the icons, and for the same reason: a committed binary
/// is a thing nobody can diff and everybody has to trust. Inline SVG rather
/// than a file, so the hero paints in the first response with no second
/// request.
///
/// The colours are fixed rather than themed. A logo that changes colour with
/// the reader's system settings is not a logo, and the plate is dark in both
/// themes for the same reason an app icon is: it is the app icon.

import { useId } from "react";

/// The two quadrants of U+259A, in a 240×240 box.
///
/// In the character the quadrants meet at a single point. Here they are pulled
/// apart by `GAP`, because two machines that touch have nothing between them
/// to draw, and what is between them is the entire product.
const SIDE = 72;
const UL = 40;
const LR = 128;
const GAP = LR - (UL + SIDE);

export function Logo({ className }: { className?: string }) {
  // The mark appears more than once on a page — the hero and the footer — and
  // two copies of `id="wisq-plate"` is invalid HTML that only looks fine
  // because both gradients happen to be identical. React's useId is stable
  // across the server render and hydration, so the markup still matches; the
  // colons it produces are legal in an id but noisy inside a URL reference.
  const uid = useId().replace(/:/g, "");
  const plate = `wisq-plate-${uid}`;
  const mark = `wisq-mark-${uid}`;
  const clip = `wisq-window-${uid}`;

  return (
    <svg
      className={className}
      viewBox="0 0 240 240"
      width="240"
      height="240"
      // The header wordmark already names the site and the heading follows
      // immediately, so announcing this too would only repeat both.
      aria-hidden="true"
      focusable="false"
    >
      <defs>
        <linearGradient id={plate} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#171d26" />
          <stop offset="1" stopColor="#0b0d10" />
        </linearGradient>
        <linearGradient id={mark} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#a8a2ff" />
          <stop offset="1" stopColor="#6f64ff" />
        </linearGradient>
        <clipPath id={clip}>
          <rect x={UL} y={UL} width={SIDE} height={SIDE} rx="13" />
        </clipPath>
      </defs>

      <rect width="240" height="240" rx="54" fill={`url(#${plate})`} />
      <rect
        x="0.75"
        y="0.75"
        width="238.5"
        height="238.5"
        rx="53.25"
        fill="none"
        stroke="#8b83ff"
        strokeOpacity="0.16"
        strokeWidth="1.5"
      />

      {/* The link: three steps across the gap, the one thing on the plate that
          is not a solid object, because a network is not one either. */}
      {[0.16, 0.5, 0.84].map((step) => (
        <circle
          key={step}
          cx={UL + SIDE + GAP * step}
          cy={UL + SIDE + GAP * step}
          r="2.5"
          fill="#8b83ff"
          fillOpacity={0.38 + step * 0.5}
        />
      ))}

      {/* Upper left: a machine somewhere else, so it is a window. */}
      <g clipPath={`url(#${clip})`}>
        <rect x={UL} y={UL} width={SIDE} height={SIDE} fill={`url(#${mark})`} />
        <rect x={UL} y={UL} width={SIDE} height="19" fill="#0b0d10" fillOpacity="0.3" />
        <circle cx={UL + 13} cy={UL + 9.5} r="3" fill="#0b0d10" fillOpacity="0.42" />
        <circle cx={UL + 25} cy={UL + 9.5} r="3" fill="#0b0d10" fillOpacity="0.42" />
      </g>

      {/* Lower right: the phone in your hand, screen and all. */}
      <rect x={LR} y={LR} width={SIDE} height={SIDE} rx="13" fill={`url(#${mark})`} />
      <rect
        x={LR + 19}
        y={LR + 11}
        width="34"
        height="50"
        rx="7"
        fill="#0b0d10"
        fillOpacity="0.32"
      />
      <rect
        x={LR + 29}
        y={LR + 54}
        width="14"
        height="2.8"
        rx="1.4"
        fill="#0b0d10"
        fillOpacity="0.5"
      />
    </svg>
  );
}
