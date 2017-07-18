#ValidationTags#FlowControl,Pipeline#
Function Get-DbaADObject
{
<#
.SYNOPSIS
Get-DbaADObject tries to facilitate searching AD with dbatools, which ATM can't require AD cmdlets.

.DESCRIPTION
As working with multiple domains, forests, ldap filters, partitions, etc is quite hard to grasp, let's try to do "the right thing" here and
facilitate everybody's work with it. It either returns the exact matched result or None if it isn't found. You can inspect the raw object
calling GetUnderlyingObject() on the returned object.

.PARAMETER ADObject
Pass in both the domain and the login name in Domain\sAMAccountName format (the one everybody is accustomed to)
You can also pass a UserPrincipalName format (with the correct IdentityType, either with Domain\UserPrincipalName or UserPrincipalName@Domain)
Beware: the "Domain" part of the UPN *can* be different from the real domain, see "UPN suffixes" (https://msdn.microsoft.com/en-us/library/windows/desktop/aa380525(v=vs.85).aspx)
It's always best to pass the real domain name in (see the examples)
For any other format, please beware that the domain part must always be specified (again, for the best result, before the slash)

.PARAMETER Type
You *should* always know what you are asking for. Please pass in Computer,Group or User to help speeding up the search

.PARAMETER IdentityType
By default objects are searched using sAMAccountName format, here you can pass different representation that need to match the passed in ADObject

.PARAMETER Credential
Use this credential to connect to the domain and search for the needed ADObject. If not passed, uses the current process' one.

.PARAMETER SearchAllDomains
Search for the object in all domains connected to the current one. If you are unsure what domain the object is coming from,
using this switch will search through all domains in your forest and also in the ones that are trusted. This is HEAVY, but it can save
some headaches.

.PARAMETER Silent
Use this switch to disable any kind of verbose messages

.NOTES
Author: Niphlod, https://github.com/niphlod

dbatools PowerShell module (https://dbatools.io, clemaire@gmail.com)

Copyright (C) 2016 Chrissy LeMaire
This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.
This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
You should have received a copy of the GNU General Public License along with this program.  If not, see <http://www.gnu.org/licenses/>.

.EXAMPLE
Get-DbaADObject -ADObject "contoso\ctrlb" -Type User

Searches in the contoso domain for a ctrlb user

.EXAMPLE
Get-DbaADObject -ADObject "ctrlb@contoso.com" -Type User -IdentityType UserPrincipalName

Searches in the contoso domain for a ctrlb user using the UserPrincipalName format. Again, beware of the UPN suffixes in elaborate AD structures!

.EXAMPLE
Get-DbaADObject -ADObject "contoso\ctrlb@super.contoso.com" -Type User -IdentityType UserPrincipalName

Searches in the contoso domain for a ctrlb@super.contoso.com user using the UserPrincipalName format. This kind of search is better than the previous one
because it takes into account possible UPN suffixes

.EXAMPLE
Get-DbaADObject -ADObject "ctrlb@super.contoso.com" -Type User -IdentityType UserPrincipalName -SearchAllDomains

As a last resort, searches in all the current forest for a ctrlb@super.contoso.com user using the UserPrincipalName format

.EXAMPLE
Get-DbaADObject -ADObject "contoso\sqlcollaborative" -Type Group

Searches in the contoso domain for a sqlcollaborative group

.EXAMPLE
Get-DbaADObject -ADObject "contoso\SqlInstance2014$" -Type Group

Searches in the contoso domain for a SqlInstance2014 computer (remember the ending $ for computer objects)

.EXAMPLE
Get-DbaADObject -ADObject "contoso\ctrlb" -Type User -Silent

Searches in the contoso domain for a ctrlb user, suppressing all error messages and throw exceptions that can be caught instead

#>
	[CmdletBinding()]
	Param (
		[string[]]$ADObject,
		[ValidateSet("User","Group","Computer")]
		[string]$Type,

		[ValidateSet("DistinguishedName","Guid","Name","SamAccountName","Sid","UserPrincipalName")]
		[string]$IdentityType = "SamAccountName",

		$Credential,
		[switch]$SearchAllDomains,
		[switch]$Silent
	)
	BEGIN {
		try {
			Add-Type -AssemblyName System.DirectoryServices.AccountManagement
		} catch {
			Stop-Function -Message "Failed to load the required module $($_.Exception.Message)" -Silent $Silent -InnerErrorRecord $_
			return
		}
		switch ($Type) {
			"User" {
				$searchClass = [System.DirectoryServices.AccountManagement.UserPrincipal]
			}
			"Group" {
				$searchClass = [System.DirectoryServices.AccountManagement.GroupPrincipal]
			}
			"Computer" {
				$searchClass = [System.DirectoryServices.AccountManagement.ComputerPrincipal]
			}
			default {
				$searchClass = [System.DirectoryServices.AccountManagement.Principal]
			}
		}
		
		function Get-DbaADObjectInternal($Domain, $IdentityType, $obj, $Silent) {
			try {
				# can we simply resolve the passed domain ? This has the benefit of raising almost instantly if the domain is not valid
				$Context = New-Object System.DirectoryServices.ActiveDirectory.DirectoryContext('Domain', $Domain)
				$DContext = [System.DirectoryServices.ActiveDirectory.Domain]::GetDomain($Context)
				if ($Credential) {
					$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $Domain, $Credential.UserName, $Credential.GetNetworkCredential().Password)
				} else {
					$ctx = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Domain', $Domain)
				}
				$found = $searchClass::FindByIdentity($ctx, $IdentityType, $obj)
				$found
			} catch {
				Stop-Function -Message "Errors trying to connect to the domain $Domain $($_.Exception.Message)" -Silent $Silent -InnerErrorRecord $_ -Target $ADObj
			}
		}
	}
	PROCESS {
		if (Test-FunctionInterrupt) { return }
		foreach($ADObj in $ADObject) {
			# passing the domain as the first part before the \ wins always in defining the domain to search into
			$Splitted = $ADObj.Split("\")
			if ($Splitted.Length -ne 2) {
				# we can also take the object@domain format
				$Splitted = $ADObj.Split("@")
				if ($Splitted.Length -ne 2) {
					Stop-Function -Message "You need to pass ADObject either DOMAIN\object or object@domain format" -Continue -Silent $Silent
				} else {
					if($IdentityType -ne 'UserPrincipalName') {
						$obj, $Domain = $Splitted
					} else {
						# if searching for a UserPrincipalName format without a specific domain passed in before the slash, 
						# we can assume there are no custom UPN suffixes in place
						$obj, $Domain = $AdObj, $Splitted[1]
					}
				}
			} else {
				$Domain, $obj = $Splitted
			}
			if ($SearchAllDomains) {
				Write-Message -Message "Searching for $obj under all domains in $IdentityType format" -Level 4 -Silent $Silent
				# if we're lucky, we can resolve the domain right away
				try {
					Get-DbaADObjectInternal -Domain $Domain -IdentityType $IdentityType -obj $obj -Silent $true
				} catch {
					# if not, let's build up all domains
					$ForestObject = [System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest()
					$AllDomains = $ForestObject.Domains.Name
					foreach($ForestDomain in $AllDomains) {
						Write-Message -Message "Searching for $obj under domain $ForestDomain in $IdentityType format" -Level 4 -Silent $Silent
						$found = Get-DbaADObjectInternal -Domain $ForestDomain -IdentityType $IdentityType -obj $obj
						if ($found) {
							$found
							break
						}
					}
					# we are very unlucky, let's search also in all trusted domains
					$AllTrusted = ($ForestObject.GetAllTrustRelationships().TopLevelNames | where Status -eq 'Enabled').Name
					foreach($ForestDomain in $AllTrusted) {
						Write-Message -Message "Searching for $obj under domain $ForestDomain in $IdentityType format" -Level 4 -Silent $Silent
						$found = Get-DbaADObjectInternal -Domain $ForestDomain -IdentityType $IdentityType -obj $obj
						if ($found) {
							$found
							break
						}
					}
				}
			} else {
				Write-Message -Message "Searching for $obj under domain $domain in $IdentityType format" -Level 4 -Silent $Silent
				Get-DbaADObjectInternal -Domain $Domain -IdentityType $IdentityType -obj $obj
			}
			
		}
	}
}

