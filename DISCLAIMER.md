# Disclaimer

**You are responsible for your own hardware. Use this software entirely at your own risk.**

`gpu-tune` changes graphics clock limits on your NVIDIA GPU through
`nvidia-smi`. Even though clock limits are reversible and are cleared by a
reboot, applying them can have consequences.

## No warranty

This software is provided "as is", without warranty of any kind, express or
implied, including but not limited to the warranties of merchantability,
fitness for a particular purpose and non-infringement.

## No liability

To the maximum extent permitted by applicable law, the author(s) and
contributor(s) of this project accept **no liability** for any direct,
indirect, incidental, special, consequential or punitive damages, including
but not limited to:

- damage to the graphics card, motherboard, power supply, cooling system or any
  other hardware
- instability, crashes, black screens, corrupted output or data loss
- reduced performance, throttling or unexpected clock behaviour
- voided manufacturer warranty
- loss of income, mining revenue or business interruption
- any other loss arising from the use or inability to use this software

## Your responsibilities

By using this software you accept that you are responsible for:

1. **Verifying temperatures yourself.** Do not rely on the defaults; check the
   card's temperature and hotspot sensors with a trusted tool.
2. **Knowing your hardware.** Clock locking is not supported on every card, and
   some laptop GPUs have vendor power management that overrides it.
3. **Not leaving the machine unattended during tuning.** A fan failure or a
   blocked airflow path during a clock change can overheat the card.
4. **Backing up important work.** Clock changes should not affect data, but
   driver instability can.
5. **Checking your warranty terms.** Overclocking and clock modification may
   void the manufacturer's warranty.

## Reversibility

Clock limits set with `nvidia-smi -lgc` are not permanent:

- `nvidia-smi -rgc` (or `gpu-tune -Mode Clear`) releases them
- shutting down or rebooting the machine also clears them

They are not written to disk and do not modify the card's VBIOS.

## Trademarks

NVIDIA, GeForce, RTX, Quadro and Tesla are trademarks of NVIDIA Corporation.
This project is not affiliated with, endorsed by, or supported by NVIDIA.
