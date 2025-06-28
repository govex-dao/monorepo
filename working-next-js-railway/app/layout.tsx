import type { Metadata } from "next";
import { Providers } from "./providers";
import "./styles/base.css";

export const metadata: Metadata = {
  title: "GovEx Trading",
  description: "Futarchy-based governance trading platform",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <body>
        <Providers>{children}</Providers>
      </body>
    </html>
  );
}
