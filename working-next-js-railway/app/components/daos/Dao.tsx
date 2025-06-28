import { ApiDaoObject } from '../../types/types';
import { Card, Button } from "@radix-ui/themes";
import { ExplorerLink } from "../ExplorerLink";
import { useCurrentAccount } from "@mysten/dapp-kit";
import { formatAddress } from "@mysten/sui/utils";

export function Dao({ dao }: { dao: ApiDaoObject }) {
  const account = useCurrentAccount();
  const isAdmin = account?.address === dao.admin;

  return (
    <Card className="p-4">
      <div className="flex justify-between items-center">
        <div>
          <p className="text-sm">Admin: {formatAddress(dao.admin)}</p>
          <ExplorerLink id={dao.objectId} type="object" />
          {dao.feePaid && (
            <p className="text-sm text-gray-600">Fee Paid: {dao.feePaid}</p>
          )}
        </div>
        {isAdmin && <Button className="cursor-pointer">Manage DAO</Button>}
      </div>
    </Card>
  );
}
