import type { Metadata } from "next";
import { Providers } from "./providers";
import { Header } from "./components/navigation/Header";
import { Footer } from "./components/navigation/Footer";
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
    <html lang="en" className="dark-theme" style={{ colorScheme: "dark" }}>
      <body>
        <Providers>
          <div className="min-h-screen flex flex-col">
            <Header />
            <main className="flex-grow">
              {children}
            </main>
            <Footer />
          </div>
        </Providers>
      </body>
    </html>
  );
}
