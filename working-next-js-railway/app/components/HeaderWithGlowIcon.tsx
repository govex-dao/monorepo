import { Box, Heading } from "@radix-ui/themes";

export function HeaderWithGlowIcon() {
  return (
    <Box>
      <Heading className="flex items-center gap-1 h-full pl-2 pr">
        <svg
          xmlns="http://www.w3.org/2000/svg"
          viewBox="0 0 100 100"
          className="w-6 h-6 mr-3 filter drop-shadow-[0_0_5px_rgba(255,255,255,0.3)] drop-shadow-[0_0_15px_rgba(255,255,255,0.2)] drop-shadow-[0_0_25px_rgba(255,255,255,0.1)]"
        >
          <rect
            x="0"
            y="0"
            width="70"
            height="100"
            fill="#808080"
            rx="20"
            ry="20"
          />
          <path d="M50 0h30c11 0 20 9 20 20v30h-50z" fill="white" />
          <path d="M50 50h50v30c0 11-9 20-20 20h-30z" fill="#000" />
        </svg>
        Govex
      </Heading>
    </Box>
  );
}
