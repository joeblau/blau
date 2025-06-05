import { useAccount, useDisconnect } from "wagmi";

export function Portfolio() {
  const account = useAccount();
  const { disconnect } = useDisconnect();

  return (
    <div>
      <div>
        <div>
          {account.address
            ? account.address.slice(0, 6) + "..." + account.address.slice(-4)
            : "No account"}
        </div>
        <button onClick={() => disconnect()}>Sign out</button>
      </div>
    </div>
  );
}
