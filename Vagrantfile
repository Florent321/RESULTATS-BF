# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# =============================================================================
# RÉSULTATS-BF — Vagrantfile : SOURCE UNIQUE DE VÉRITÉ de l'infrastructure
# =============================================================================
# Toute machine, adresse IP et taille mémoire est décrite ICI, et nulle part
# ailleurs. À chaque commande vagrant, ce fichier engendre :
#   - config/noeuds.yml : les machines actives, lues par les scripts
#     (/etc/hosts dès l'étape 1, configuration HAProxy à l'étape 4) ;
#   - .env : les secrets manquants, tirés au hasard (jamais versionnés).
#
# Paramètres, sur la ligne de commande (Git Bash) :
#   NB_APP=4 vagrant up    nombre de serveurs applicatifs, de 2 à 9
#   GROUPE=14 vagrant up   numéro de groupe, de 1 à 20 (sinon : config/groupe)
# =============================================================================

Vagrant.require_version ">= 2.4.0"

require "fileutils"
require "securerandom"
require "yaml"

# --- 1. Paramètres ------------------------------------------------------------
# Dossier du Vagrantfile : les chemins ne dépendent pas du dossier courant.
RACINE = File.expand_path(File.dirname(__FILE__))

# Le numéro de groupe vit dans le petit fichier versionné config/groupe (un
# nombre de 1 à 20) : remplacer le Vagrantfile ne l'efface donc jamais.
FICHIER_GROUPE    = File.join(RACINE, "config", "groupe")
NB_APP_PAR_DEFAUT = 2
NB_APP_MAX        = 9   # app1..app9 = .21 à .29 ; au-delà, collision avec bdd1 (.31)

BOITE         = "bento/ubuntu-24.04"
VERSION_BOITE = "202510.26.0"   # épinglée : identique pour les quatre membres

# Fonctions rangées dans un module : une méthode définie au premier niveau
# d'un Vagrantfile devient globale et peut entrer en conflit avec Vagrant.
module ResultatsBF
  module_function

  # Lit un entier dans l'environnement et le borne ; arrête tout sinon.
  def parametre_entier(nom, defaut, min, max)
    brut = ENV.fetch(nom, defaut.to_s).strip
    valeur = brut.match?(/\A\d+\z/) ? brut.to_i : nil
    return valeur if valeur && valeur.between?(min, max)

    abort "ERREUR : #{nom}=#{brut.inspect} est invalide " \
          "(entier de #{min} à #{max} attendu)."
  end

  # Une ligne de l'inventaire (énoncé §3.1).
  def machine(reseau, nom, octet, mem, role, actif = true)
    { "nom" => nom, "ip" => "#{reseau}.#{octet}", "mem" => mem,
      "role" => role, "actif" => actif }
  end

  # Écrit un fichier seulement si son contenu change, toujours en fins de
  # ligne LF (écriture binaire : pas de conversion CRLF sous Windows).
  def ecrire_si_different(chemin, contenu)
    contenu = contenu.b
    return false if File.exist?(chemin) && File.binread(chemin) == contenu

    FileUtils.mkdir_p(File.dirname(chemin))
    File.binwrite(chemin, contenu)
    true
  end

  # Complète .env avec les variables déclarées dans .env.exemple : chaque
  # variable absente reçoit une valeur aléatoire. Rien n'est affiché.
  def completer_secrets(racine)
    modele = File.join(racine, ".env.exemple")
    cible  = File.join(racine, ".env")
    abort "ERREUR : #{modele} introuvable." unless File.exist?(modele)

    noms = File.binread(modele).lines
               .map { |l| l[/\A([A-Z_][A-Z0-9_]*)=/, 1] }.compact
    existant = File.exist?(cible) ? File.binread(cible) : "".b
    presents = existant.lines.map { |l| l[/\A\s*([A-Z_][A-Z0-9_]*)=/, 1] }.compact
    manquants = noms - presents

    unless manquants.empty?
      ajout = +""
      if existant.empty?
        ajout << "# Secrets locaux engendrés par le Vagrantfile.\n"
        ajout << "# NE JAMAIS VERSIONNER ce fichier (voir .gitignore).\n"
      elsif !existant.end_with?("\n")
        ajout << "\n"
      end
      manquants.each { |nom| ajout << "#{nom}=#{SecureRandom.hex(16)}\n" }
      File.binwrite(cible, existant + ajout.b)
      puts "==> .env : secret(s) engendré(s) au hasard : #{manquants.join(', ')}"
    end

    faibles = existant.lines.grep(/=a_remplacer\s*\z/)
                      .map { |l| l.split("=", 2).first.strip }
    unless faibles.empty?
      warn "ATTENTION : valeur « a_remplacer » dans .env pour #{faibles.join(', ')}."
    end
  end
end

groupe_lu = File.exist?(FICHIER_GROUPE) ? File.binread(FICHIER_GROUPE).delete("^0-9") : ""
if ENV.fetch("GROUPE", "").strip.empty? && groupe_lu.empty?
  abort "ERREUR : numéro de groupe inconnu. Dans Git Bash, à la racine du dépôt :\n" \
        "  echo 14 > config/groupe    (votre numéro de groupe)\n" \
        "puis commitez ce fichier : tous les membres utilisent le même."
end
GROUPE = ResultatsBF.parametre_entier("GROUPE", groupe_lu, 1, 20)
NB_APP = ResultatsBF.parametre_entier("NB_APP", NB_APP_PAR_DEFAUT, 2, NB_APP_MAX)
RESEAU = "192.168.#{55 + GROUPE}"   # X = 55 + G (énoncé §7.1)
# L'énoncé prévoit les groupes 1 à 8, soit 192.168.56.0 à 192.168.63.255 : la seule
# plage que VirtualBox accepte sans réglage sur un hôte Linux ou macOS. Sous Windows,
# VirtualBox accepte aussi les numéros suivants (192.168.64.x et au-delà).
if GROUPE > 8 && %w[up reload provision].include?(ARGV.first)
  warn "ATTENTION : groupe #{GROUPE}, réseau #{RESEAU}.0/24, hors de la plage 192.168.56.0/21 " \
       "de l'énoncé (§7.1). VirtualBox l'accepte sous Windows, pas sous Linux ni macOS : " \
       "faites valider ce réseau par l'enseignant."
end

# --- 2. Inventaire des machines (énoncé §3.1) ------------------------------------
# L'ordre compte : vagrant up démarre les machines dans cet ordre.
MACHINES = []
MACHINES << ResultatsBF.machine(RESEAU, "bdd1", 31, 768, "bdd")
MACHINES << ResultatsBF.machine(RESEAU, "bdd2", 32, 768, "replique")
(1..NB_APP_MAX).each do |i|
  # app(N+1) à app9 sont définies mais inactives : vagrant up ne les démarre
  # pas, et vagrant destroy -f les supprime si elles existent encore.
  MACHINES << ResultatsBF.machine(RESEAU, "app#{i}", 20 + i, 512, "app", i <= NB_APP)
end
MACHINES << ResultatsBF.machine(RESEAU, "lb1", 11, 512, "lb")

# Les machines ACTIVES forment la source de vérité transmise aux scripts.
NOEUDS = MACHINES.select { |m| m["actif"] }
                 .map { |m| m.reject { |cle, _| cle == "actif" } }

# --- 3. Fichiers engendrés -----------------------------------------------------
ResultatsBF.ecrire_si_different(
  File.join(RACINE, "config", "noeuds.yml"),
  "# Fichier ENGENDRÉ par le Vagrantfile à chaque commande vagrant.\n" \
  "# Ne pas le modifier à la main : modifier le Vagrantfile.\n" +
  { "groupe" => GROUPE, "reseau" => "#{RESEAU}.0/24",
    "nb_app" => NB_APP, "noeuds" => NOEUDS }.to_yaml
)
ResultatsBF.completer_secrets(RACINE)

# --- 4. Machines virtuelles -----------------------------------------------------
Vagrant.configure("2") do |config|
  config.vm.box              = BOITE
  config.vm.box_version      = VERSION_BOITE
  config.vm.box_check_update = false   # pas de requête réseau à chaque commande
  config.vm.boot_timeout     = 600     # postes lents : 10 minutes au lieu de 5

  # Le dépôt est visible dans chaque VM sous /vagrant (Additions invité).
  config.vm.synced_folder ".", "/vagrant", type: "virtualbox"

  # Plugin vagrant-vbguest neutralisé s'il est installé : il mettrait à jour
  # les Additions invité à chaque VM (téléchargements, échecs possibles).
  if Vagrant.has_plugin?("vagrant-vbguest")
    config.vbguest.auto_update = false
  end

  config.vm.provider "virtualbox" do |vb|
    vb.linked_clone = true   # chaque VM = différence d'une copie unique de la boîte
    vb.cpus         = 1
  end

  MACHINES.each do |n|
    config.vm.define n["nom"], autostart: n["actif"] do |m|
      m.vm.hostname = n["nom"]
      m.vm.network "private_network", ip: n["ip"]

      if n["role"] == "lb"
        # R8 : seul le répartiteur expose un port vers l'hôte, et seulement
        # sur l'hôte lui-même (127.0.0.1). auto_correct : si 8080 est déjà
        # pris, Vagrant choisit un autre port au lieu d'échouer (R1).
        m.vm.network "forwarded_port", id: "http", guest: 80, host: 8080,
                     host_ip: "127.0.0.1", auto_correct: true
      end

      m.vm.provider "virtualbox" do |vb|
        vb.memory = n["mem"]
      end

      # Les deux provisionneurs sont rejoués à CHAQUE vagrant up (run: "always") :
      # les configurations engendrées (pg_hba.conf, HAProxy…) suivent ainsi
      # NB_APP sans geste manuel. Contrepartie : tout doit être idempotent (R2).
      # 1) Socle commun : paquets, /etc/hosts.
      m.vm.provision "commun", type: "shell", path: "scripts/commun.sh",
                     args: [n["role"]], run: "always"
      # 2) Script du rôle : bdd.sh, replique.sh, app.sh ou lb.sh.
      m.vm.provision "role", type: "shell", path: "scripts/#{n['role']}.sh",
                     run: "always"
    end
  end
end
