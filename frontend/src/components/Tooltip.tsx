import { Tooltip as RadixTooltip } from "@radix-ui/themes";
import { ReactNode } from "react";

interface TooltipProps {
  content: ReactNode;
  children: ReactNode;
}

export function Tooltip({ content, children }: TooltipProps) {
  return (
    <RadixTooltip
      content={
        <div className="bg-gray-800/95 text-gray-100 p-2 rounded-md shadow-lg border border-gray-700 backdrop-blur-sm">
          {content}
        </div>
      }
    >
      {children}
    </RadixTooltip>
  );
} 