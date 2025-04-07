import { createBrowserRouter } from "react-router-dom";
import { Root } from "./root";
import { CreateDashboard } from "@/routes/CreateDashboard";
import { LearnDashboard } from "@/routes/LearnDashboard";
import { TradeDashboard } from "@/routes/TradeDashboard";
import { ProposalView } from "@/routes/ProposalView";

export const router = createBrowserRouter([
  {
    path: "/",
    element: <Root />,
    children: [
      {
        index: true,
        element: <TradeDashboard />, // This will handle /?dao={daoid}
      },
      {
        path: "create",
        element: <CreateDashboard />, // This will handle /create?dao={daoid}
      },
      {
        path: "learn",
        element: <LearnDashboard />,
      },
      {
        path: "trade/:proposalId",
        element: <ProposalView />,
      },
    ],
  },
]);
