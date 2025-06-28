export type ApiLockedObject = {
  id?: string;
  objectId: string;
  keyId: string;
  creator?: string;
  itemId: string;
  deleted: boolean;
};

export type ApiEscrowObject = {
  id: string;
  objectId: string;
  sender: string;
  recipient: string;
  keyId: string;
  itemId: string;
  swapped: boolean;
  cancelled: boolean;
};

export type EscrowListingQuery = {
  escrowId?: string;
  sender?: string;
  recipient?: string;
  cancelled?: string;
  swapped?: string;
  limit?: string;
};

export type LockedListingQuery = {
  deleted?: string;
  keyId?: string;
  limit?: string;
};

export type ApiDaoObject = {
  id: number;
  objectId: string;
  admin: string;
  feePaid?: number;
  timestamp: string; // Changed from bigint to string
};

export type DaoListingQuery = {
  admin?: string;
};

// Add to your types file:
export type DaoSearchQuery = {
  objectId?: string;
  limit?: string;
};
