"""Vayu MCP prompts — guided analysis workflows."""


def daglig_check() -> str:
    """Daglig traning: beredskap, senaste pass, rekommendation."""
    return (
        "Gör en daglig träningscheck:\n\n"
        "1. Hämta beredskap med get_readiness(n=7) — senaste veckans trend\n"
        "2. Hämta senaste pass med get_sessions(n=5)\n"
        "3. Hämta belastning med get_training_load(metric='acwr', n=7)\n\n"
        "Baserat på resultaten:\n"
        "- Sammanfatta dagens beredskap och trend\n"
        "- Kommentera senaste passets effekt\n"
        "- Ge en enkel rekommendation: vila, lätt pass, eller normal träning\n"
        "- Om ACWR > 1.3: varna för hög belastningsökning\n"
        "- Om beredskap < 40: rekommendera vila\n"
    )


def veckoutvardering(weeks_back: int = 1) -> str:
    """Veckoanalys: volym, intensitetsbalans, trender."""
    return (
        f"Gör en veckoutvärdering (senaste {weeks_back} veckor):\n\n"
        f"1. Hämta pass med get_sessions(after='-{weeks_back}w')\n"
        f"2. Hämta belastning med get_training_load(metric='pmc', after='-{weeks_back}w')\n"
        f"3. Hämta zondistribution med get_zones(after='-{max(weeks_back * 4, 4)}w')\n\n"
        "Analysera:\n"
        "- Total veckovolym (km) och jämför med föregående vecka\n"
        "- Intensitetsbalans (Z1/Z2/Z3-fördelning)\n"
        "- Monotoni (variation i daglig belastning)\n"
        "- ACWR-trend (belastningsförändring)\n"
        "- Ge konkreta förslag för kommande vecka\n"
    )


def konditionsbedomning(months: int = 3) -> str:
    """Konditionsbedömning: EF/HRE-trend, CTL-utveckling, zondistribution."""
    return (
        f"Gör en konditionsbedömning (senaste {months} månader):\n\n"
        f"1. Hämta EF-trend med get_efficiency(metric='ef', after='-{months}m', plot=True)\n"
        f"2. Hämta PMC med get_training_load(metric='pmc', after='-{months}m', plot=True)\n"
        f"3. Hämta zoner med get_zones(after='-{months}m', plot=True)\n"
        f"4. Hämta dekopp med get_decoupling(after='-{months}m')\n\n"
        "Bedöm:\n"
        "- EF-trend: förbättras, stabil eller försämras?\n"
        "- CTL-nivå och utveckling (konditionsindex)\n"
        "- Träningsbalans: tillräckligt polariserad? (PI > 2.0 = bra)\n"
        "- Aerob koppling: decoupling < 5% = vältränad aerob bas\n"
        "- Sammanfatta konditionsstatus och ge rekommendationer\n"
    )
