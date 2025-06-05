"use client";
import { NavigationHeader } from "@/components/blau/dapp/navigation-header";
import { TokenList } from "@/components/blau/dapp/token-list";

export function Portfolio() {
  return (
    <div className="max-w-md mx-auto p-4">
      <NavigationHeader />
      <TokenList />
    </div>
    // <div>
    //   <div>
    //     <div>
    //       {account.address
    //         ? account.address.slice(0, 6) + "..." + account.address.slice(-4)
    //         : "No account"}
    //     </div>
    //     <button onClick={() => disconnect()}>Sign out</button>
    //   </div>
    // </div>
  );
}
