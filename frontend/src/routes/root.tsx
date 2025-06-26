import { Toaster } from "react-hot-toast";
import { Outlet, useLocation } from "react-router-dom";
import { Header } from "@/components/navigation/Header";
import { Container } from "@radix-ui/themes";
import { MinimalFooter } from "@/components/navigation/Footer";
import { ClientOnly } from "@/components/ClientOnly";
import { Helmet } from "react-helmet-async";


export function Root() {
  const location = useLocation();

  // Determine title based on route
  let title = "Govex - Futarchy on Sui";
  
  switch (location.pathname) {
    case "/create":
      title = "Create - Govex";
      break;
    case "/learn":
      title = "Learn - Govex";
      break;
  }

  return (
    <div className="h-screen flex flex-col justify-start items-start">
      <Helmet>
        <title>{title}</title>
      </Helmet>
      <Toaster position="bottom-center" />
      <ClientOnly>
        <Header />
      </ClientOnly>
      <Container py="4" className="flex-1 flex flex-col justify-start w-screen h-full overflow-y-scroll">
        <Outlet />
      </Container>
      <MinimalFooter />
    </div>
  );
}
